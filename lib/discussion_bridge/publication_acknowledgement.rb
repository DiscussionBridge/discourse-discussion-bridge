# frozen_string_literal: true

module DiscussionBridge
  module PublicationAcknowledgement
    FIELDS = %w[lease_token resource_id source_revision source_revision_sequence policy_revision destination_policy_id action stage stage_token destination_binding synchronized_at deployment_state verification_state correlation_id].freeze
    IDENTITY_FIELDS = %w[resource_id destination_policy_id action].freeze
    REVISION_FIELDS = %w[source_revision source_revision_sequence policy_revision].freeze
    PROFILE_MODES = { "astro" => "static", "hugo" => "static", "statamic_ssg" => "static",
      "ghost" => "dynamic", "statamic_flat" => "dynamic", "statamic_db" => "dynamic",
      "wordpress" => "dynamic", "discourse_as_publisher" => "dynamic" }.freeze

    def self.profile_mode!(profile)
      PROFILE_MODES.fetch(profile) { DestinationPolicy.fail_with("reconciliation_required") }
    end

    def self.validate!(request)
      DestinationPolicy.object!(request, FIELDS, %w[deployed_at publicly_verified_at])
      %w[lease_token stage_token].each do |field|
        DestinationPolicy.fail_with(field == "stage_token" ? "stage_conflict" : "reconciliation_required") unless
          request[field].is_a?(String) && /\A[a-f0-9]{64}\z/.match?(request[field])
      end
      DestinationPolicy.fail_with("stage_conflict") if %w[synchronized deployed verified].exclude?(request["stage"])
      DestinationPolicy.fail_with unless %w[publish update hold unpublish restore].include?(request["action"]) &&
        request["resource_id"].is_a?(String) && /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/.match?(request["resource_id"])
      %w[source_revision policy_revision destination_policy_id].each { |field| DestinationPolicy.string!(request[field]) }
      sequence = request["source_revision_sequence"]
      DestinationPolicy.fail_with unless sequence.is_a?(Integer) && sequence.between?(1, BridgeRecordRequest::MAX_SAFE_INTEGER)
      synchronized = BridgeRecordRequest.timestamp!(request["synchronized_at"])
      case request["stage"]
      when "synchronized"
        valid = (request["deployment_state"] == "not_required" && request["verification_state"] == "not_required") ||
          (request["deployment_state"] == "pending" && request["verification_state"] == "pending")
        DestinationPolicy.fail_with unless valid && !request.key?("deployed_at") && !request.key?("publicly_verified_at")
      when "deployed", "verified"
        deployed = BridgeRecordRequest.timestamp!(request["deployed_at"])
        DestinationPolicy.fail_with unless request["deployment_state"] == "deployed" && deployed >= synchronized
        if request["stage"] == "deployed"
          DestinationPolicy.fail_with unless request["verification_state"] == "pending" && !request.key?("publicly_verified_at")
        else
          verified = BridgeRecordRequest.timestamp!(request["publicly_verified_at"])
          DestinationPolicy.fail_with unless request["verification_state"] == "verified" && verified >= deployed
        end
      end
      binding = request["destination_binding"]
      DestinationPolicy.object!(binding, %w[binding_id external_id canonical_url publication_revision content_disposition], %w[read_more_url])
      DestinationPolicy.fail_with unless binding["binding_id"].is_a?(String) && /\Adbb_[a-f0-9]{32}\z/.match?(binding["binding_id"])
      %w[external_id publication_revision].each { |field| DestinationPolicy.string!(binding[field]) }
      DestinationPolicy.string!(binding["canonical_url"], 2048)
      canonical!(binding["canonical_url"])
      if binding["content_disposition"] == "excerpt"
        DestinationPolicy.string!(binding["read_more_url"], 2048)
        canonical!(binding["read_more_url"])
      else
        DestinationPolicy.fail_with unless binding["content_disposition"] == "complete" && !binding.key?("read_more_url")
      end
    end

    def self.canonical!(url)
      value = CanonicalSource.call(connection_id: "ack-validation", source_url: url)
      DestinationPolicy.fail_with unless value.source_url == url
    end

    # The authenticated connection lock serializes claims and receipts. The
    # destination projection is independent of the retained baseline binding.
    def self.accept!(connection, public_id, request)
      PublicationWork.connection!(connection)
      validate!(request)
      work = DiscussionBridgePublicationWork.joins(:publication_destination)
        .where(discussion_bridge_publication_destinations: { content_connection_id: connection.id }).find_by!(public_id: public_id)
      destination = work.publication_destination
      destination.lock!
      work.lock!
      PublicationWork.verify!(work)
      DestinationPolicy.fail_with("work_superseded") if work.state == "superseded"
      issued = issue!(work, request)
      compare_identity!(issued.work, request)
      reference!(work, request)
      retained = DiscussionBridgePublicationReceipt.find_by(work_issue_id: issued.id, stage: request["stage"])
      if retained
        verify_receipt!(retained)
        DestinationPolicy.fail_with("stage_conflict") unless retained.request == request
        return retained.response.deep_dup
      end
      now = Time.now.utc
      transition!(work, destination, issued, request, now)
      reserve!(connection, work, destination, request["destination_binding"])
      response = persist!(connection, work, destination, request)
      DiscussionBridgePublicationReceipt.create!(work_issue: issued, stage: request.fetch("stage"), request: request.deep_dup,
        request_digest: NativeSourceRevisionCapture.fingerprint(request), response: response.deep_dup,
        response_digest: NativeSourceRevisionCapture.fingerprint(response), received_at: now)
      response
    rescue ActiveRecord::RecordNotUnique
      DestinationPolicy.fail_with("destination_collision")
    end

    def self.issue!(work, request)
      DestinationPolicy.fail_with("reconciliation_required") unless work.lease_token &&
        ActiveSupport::SecurityUtils.secure_compare(work.lease_token, request.fetch("lease_token"))
      issued = DiscussionBridgeWorkIssue.where(publication_work_id: work.id).order(id: :desc).first
      DestinationPolicy.fail_with("reconciliation_required") unless issued &&
        issued.work["work_id"] == work.public_id && issued.work["lease_token"] == work.lease_token &&
        issued.work.except("work_id", "lease_token", "stage_token", "lease_expires_at", "attempt_count", "retry_generation", "correlation_id") == work.context.fetch("work")
      issued
    end

    def self.compare_identity!(issued, request)
      DestinationPolicy.fail_with("identity_conflict") if IDENTITY_FIELDS.any? { |field| issued[field] != request[field] }
      DestinationPolicy.fail_with("revision_conflict") if REVISION_FIELDS.any? { |field| issued[field] != request[field] }
    end

    def self.reference!(work, request)
      return unless request.fetch("destination_binding")["content_disposition"] == "excerpt"
      capture = work.source_inventory_entry.native_source_revision
      DestinationPolicy.fail_with("revision_conflict") unless capture.revision == request["source_revision"] && capture.sequence == request["source_revision_sequence"]
      DestinationPolicy.fail_with("identity_conflict") unless request.fetch("destination_binding")["read_more_url"] == capture.metadata.fetch("topic_url")
    end

    def self.verify_receipt!(receipt)
      DestinationPolicy.fail_with("integrity_failed") unless receipt.request_digest == NativeSourceRevisionCapture.fingerprint(receipt.request) &&
        receipt.response_digest == NativeSourceRevisionCapture.fingerprint(receipt.response) && receipt.stage == receipt.request["stage"] &&
        receipt.response["accepted_stage"] == receipt.stage
    end

    def self.transition!(work, destination, issued, request, now)
      expected = { "synchronized" => "leased", "deployed" => "awaiting_deployment", "verified" => "awaiting_verification" }.fetch(request.fetch("stage"))
      DestinationPolicy.fail_with("stage_conflict") unless work.state == expected && destination.active_work_id == work.id &&
        work.stage_token && ActiveSupport::SecurityUtils.secure_compare(work.stage_token, request.fetch("stage_token"))
      received = now.to_datetime
      if request["stage"] == "synchronized"
        DestinationPolicy.fail_with("stage_conflict") unless issued.work["stage_token"] == request["stage_token"]
        DestinationPolicy.fail_with("work_expired") if work.lease_expires_at <= now
        synchronized = BridgeRecordRequest.timestamp!(request.fetch("synchronized_at"))
        claimed = issued.claimed_at.to_datetime
        DestinationPolicy.fail_with if synchronized < claimed || synchronized > received || received < claimed
        dynamic = request["deployment_state"] == "not_required"
        DestinationPolicy.fail_with("stage_conflict") unless dynamic == (work.destination_mode == "dynamic")
      else
        DestinationPolicy.fail_with("stage_conflict") unless work.destination_mode == "static"
        previous_stage = request["stage"] == "deployed" ? "synchronized" : "deployed"
        previous = DiscussionBridgePublicationReceipt.find_by!(work_issue_id: issued.id, stage: previous_stage)
        verify_receipt!(previous)
        DestinationPolicy.fail_with("identity_conflict") if previous.request["destination_binding"] != request["destination_binding"] ||
          previous.request["synchronized_at"] != request["synchronized_at"] ||
          (previous_stage == "deployed" && previous.request["deployed_at"] != request["deployed_at"])
        DestinationPolicy.fail_with("stage_conflict") unless previous.response["next_stage_token"] == request["stage_token"]
        event = request["stage"] == "deployed" ? "deployed_at" : "publicly_verified_at"
        DestinationPolicy.fail_with if BridgeRecordRequest.timestamp!(request.fetch(event)) > received
      end
    end

    def self.reserve!(connection, work, destination, binding)
      url = binding.fetch("canonical_url")
      DestinationPolicy.fail_with("scope_denied") unless connection.allows_origin?(url)
      existing = destination.binding
      if existing
        DestinationPolicy.fail_with("integrity_failed") unless destination.binding_digest == NativeSourceRevisionCapture.fingerprint(existing)
        DestinationPolicy.fail_with("identity_conflict") unless existing.slice("binding_id", "external_id", "canonical_url") ==
          binding.slice("binding_id", "external_id", "canonical_url")
      end
      origin = URI.parse(url).then { |uri| "#{uri.scheme}://#{uri.host}#{uri.port == uri.default_port ? "" : ":#{uri.port}"}" }
      identity_digest = Digest::SHA256.hexdigest("#{origin}\n#{binding.fetch("external_id")}")
      url_digest = Digest::SHA256.hexdigest(url)
      collisions = DiscussionBridgePublicationDestination.where.not(id: destination.id).where(
        "binding_public_id = :binding OR native_identity_digest = :identity OR native_url_digest = :url",
        binding: binding.fetch("binding_id"), identity: identity_digest, url: url_digest)
      original = work.source_inventory_entry.content_binding
      reserved = DiscussionBridgeContentBinding.where.not(id: original.id)
      baseline_collision = reserved.where(public_id: binding.fetch("binding_id")).exists? || reserved.where(canonical_url: url).exists? ||
        reserved.where(external_id: binding.fetch("external_id")).where("canonical_url LIKE ?", "#{origin}/%").exists?
      DestinationPolicy.fail_with("destination_collision") if collisions.exists? || baseline_collision
      destination.assign_attributes(binding_public_id: binding.fetch("binding_id"), native_identity_digest: identity_digest, native_url_digest: url_digest)
    end

    def self.persist!(connection, work, destination, request)
      terminal = work.destination_mode == "dynamic" || request["stage"] == "verified"
      state = terminal ? "acknowledged" : request["stage"] == "synchronized" ? "awaiting_deployment" : "awaiting_verification"
      next_token = terminal ? nil : SecureRandom.hex(32)
      response = { "work_id" => work.public_id, "accepted_stage" => request.fetch("stage"), "resulting_state" => state,
        "terminal" => terminal, "correlation_id" => request.fetch("correlation_id") }
      response["next_stage_token"] = next_token unless terminal
      binding = binding_payload(connection, work, request, terminal)
      destination.update!(binding: binding, binding_digest: NativeSourceRevisionCapture.fingerprint(binding), last_receipt_work_id: work.id,
        active_work_id: terminal ? nil : work.id)
      work.update!(state: state, stage_token: next_token || work.stage_token)
      response
    end

    def self.binding_payload(connection, work, request, terminal)
      binding_state = terminal ? { "hold" => "held", "unpublish" => "withdrawn" }.fetch(request["action"], "active") : "pending"
      binding = request.fetch("destination_binding").merge("connection_id" => connection.public_id, "role" => "presentation",
        "state" => binding_state, "presentation_mode" => work.context.fetch("work").fetch("presentation_mode"),
        "applied_source_revision" => request.fetch("source_revision"), "synchronized_at" => request.fetch("synchronized_at"),
        "deployment_state" => request.fetch("deployment_state"), "verification_state" => request.fetch("verification_state"))
      %w[deployed_at publicly_verified_at].each { |field| binding[field] = request.fetch(field) if request.key?(field) }
      binding
    end

    def self.projected_binding!(destination, connection)
      work = DiscussionBridgePublicationWork.find(destination.last_receipt_work_id)
      PublicationWork.verify!(work)
      DestinationPolicy.fail_with("reconciliation_required") unless work.publication_destination_id == destination.id &&
        destination.content_connection_id == connection.id
      receipt = DiscussionBridgePublicationReceipt.joins(:work_issue)
        .where(discussion_bridge_work_issues: { publication_work_id: work.id }).order(id: :desc).first!
      verify_receipt!(receipt)
      compare_identity!(work.context.fetch("work"), receipt.request)
      reference!(work, receipt.request)
      expected = binding_payload(connection, work, receipt.request, receipt.response.fetch("terminal"))
      DestinationPolicy.fail_with("integrity_failed") unless destination.binding == expected &&
        destination.binding_digest == NativeSourceRevisionCapture.fingerprint(expected) && destination.binding_public_id == expected["binding_id"]
      expected
    end
  end
end
