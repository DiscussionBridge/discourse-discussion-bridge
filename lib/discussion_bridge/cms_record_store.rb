# frozen_string_literal: true

require "digest"

module DiscussionBridge
  # Single typed boundary around the current native resolver and owned source
  # edition machinery. Source input bytes remain distinct from native context.
  class CmsRecordStore
    Result = Data.define(:status, :body)

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    def resolve(input)
      validate_resolve_envelope!(input)
      creations = []
      creator = TopicCreator.new
      result = mutation("record_resolve", "", input) do
        CmsProtocol.validate!("ToResolve", input)
        source = input.fetch("bridge_record")
        effective_lane = source["lane"] || CmsConfiguration.current!(@connection, required_direction: nil).fetch("publication_lane")
        scope_source!(source, effective_lane)
        created_at = source["source_created_at"]
        updated_at = source["source_updated_at"]
        if created_at && updated_at && Time.iso8601(updated_at) < Time.iso8601(created_at)
          CmsProtocol.reject!("invalid_field")
        end
        canonical = CanonicalSource.call(connection_id: @connection.public_id, source_url: source.fetch("canonical_url")).source_url
        if canonical != source.fetch("canonical_url")
          CmsProtocol.reject!("invalid_field")
        end
        CmsUrlReservation.with_locks([canonical]) do
        binding = DiscussionBridgeContentBinding.lock.find_by(
          content_connection_id: @connection.id, external_id: source.fetch("external_id"),
        )
        if binding && binding.canonical_url != canonical
          next conflict("canonical_url_conflict")
        end
        if binding && (binding.role != "source" || binding.state != "active")
          next conflict("identity_conflict")
        end
        if binding && binding.bridge_record.lane.to_s != effective_lane
          next conflict("identity_conflict")
        end
        stored = binding&.bridge_record&.cms_source_publication
        if stored && %w[withdrawn attention].include?(stored["state"])
          next conflict("native_ownership_conflict")
        end
        if stored
          unless source.fetch("expected_source_revision") == stored.fetch("revision")
            CmsProtocol.reject!("revision_conflict")
          end
        elsif source.fetch("expected_source_revision")
          CmsProtocol.reject!("revision_conflict")
        end
        historical = binding && DiscussionBridgeCmsToSourceRevision.find_by(
          bridge_record_id: binding.bridge_record_id, source_revision: source.fetch("source_revision"),
        )
        if historical && (!stored || stored["revision"] != source.fetch("source_revision") ||
             historical.identity_sha256 != CmsToPublication.identity(source))
          CmsProtocol.reject!("revision_conflict")
        end
        if CmsGeneratedExcerpt.generated?(source)
          CmsGeneratedExcerpt.validate_selection!(source, stored&.fetch("input", nil))
        end
        preflight_url!(binding, canonical)
        data = source.symbolize_keys
        data[:existing_topic_id] = data[:existing_topic_id].to_i if data[:existing_topic_id]
        data[:lane] = effective_lane
        data[:cms_input] = source.deep_dup
        data[:cms_synchronized_at] = CmsProtocol.instant(@clock.call)
        data[:source_publication] = {
          "revision" => source.fetch("source_revision"),
          "previous_revision" => source.fetch("expected_source_revision"),
          "created_at" => source.fetch("source_created_at"),
          "updated_at" => source.fetch("source_updated_at"),
          "content_sha256" => source.fetch("source_content_sha256"),
          "content_bytes" => source.fetch("source_content_bytes"),
          "excerpted" => source.fetch("representation").fetch("kind") != "full",
        }
        begin
          result = BridgeRecordResolver.call(
            connection: @connection, request: data, policy: policy(data),
            topic_creator: creator,
            after_commit: ->(creation) { creations << creation },
          )
        rescue ActiveRecord::RecordNotSaved
          CmsProtocol.reject!("invalid_field")
        end
        if result.outcome == "reconciliation_required"
          CmsProtocol.reject!("revision_conflict") if result.reason == "source_publication_revision_conflict"
          reason = case result.reason
          when "binding_identity_conflict" then "identity_conflict"
          when "source_publication_adoption_conflict" then "adoption_unavailable"
          else "native_ownership_conflict"
          end
          next conflict(reason)
        end
        CmsProtocol.reject!("scope_denied") if result.outcome == "rejected"
        record = DiscussionBridgeBridgeRecord.find_by!(resource_id: result.resource_id)
        receipt = record.cms_source_publication
        CmsMoveReservation.reserve!(record.active_binding("source"), canonical, state: "active")
        DiscussionBridgeCmsToSourceRevision.find_or_create_by!(
          bridge_record_id: record.id, source_revision: receipt.fetch("revision"),
        ) do |revision|
          revision.identity_sha256 = CmsToPublication.identity(source)
          revision.accepted_at = @clock.call
        end
        outcome = result.outcome == "created" ? "created" :
          (result.source_publication_outcome == "updated" ? "updated" : "resolved")
        body = {
          "outcome" => outcome,
          "reason" => { "created" => "record_created", "updated" => "source_revision_updated", "resolved" => "already_resolved" }.fetch(outcome),
          "resource_id" => record.resource_id,
          "topic_id" => record.topic_id.to_s,
          "topic_url" => record.topic.url,
          "direction" => "to_discourse",
          "source_revision" => receipt.fetch("revision"),
          "synchronized_at" => receipt.fetch("synchronized_at"),
          "core_fallback" => false,
        }
        response("ResolveResult", body, outcome == "created" ? 201 : 200)
        end
      end
    rescue PortableContent::PreparationUnavailable => error
      report_content_loss!(input, error)
      CmsProtocol.reject!("content_preservation_unavailable")
    rescue ActiveRecord::RecordInvalid, ArgumentError
      CmsProtocol.reject!("invalid_field")
    else
      # Native creation jobs must not escape before the receipt transaction succeeds.
      creations.each { |creation| creator.after_commit(creation) }
      result
    end

    def show(resource_id)
      transaction { response("Record", projection(owned_binding!(resource_id))) }
    end

    def withdraw(resource_id, input)
      CmsProtocol.validate!("UUID", resource_id)
      CmsProtocol.validate!("WithdrawInput", input)
      mutation("record_withdraw", resource_id, input) do
        binding = owned_binding!(resource_id)
        record = binding.bridge_record
        CmsProtocol.reject!("scope_denied") unless record.direction == "to_discourse"
        record.lock!
        receipt = record.cms_source_publication
        unless receipt && input.fetch("expected_source_revision") == receipt.fetch("revision")
          CmsProtocol.reject!("revision_conflict")
        end
        # Binding and URL reservation remain in place. The native topic, record
        # state and discussion are not deleted, hidden or semantically converted.
        unless receipt["state"] == "withdrawn"
          record.update!(cms_source_publication: receipt.merge(
            "state" => "withdrawn", "withdrawal_reason" => input.fetch("reason"),
            "withdrawn_at" => CmsProtocol.instant(@clock.call),
          ))
        end
        response("Record", projection(binding))
      end
    end

    def scoped_bindings
      DiscussionBridgeContentBinding.joins(:bridge_record).where(
        content_connection_id: @connection.id, state: "active",
        discussion_bridge_bridge_records: { direction: @connection.allowed_directions },
      ).includes(bridge_record: :topic).order(:id)
    end

    def binding_available?(binding)
      record = binding.bridge_record
      role = record.direction == "to_discourse" ? "source" : "presentation"
      binding.content_connection_id == @connection.id && binding.state == "active" &&
        binding.role == role && @connection.allows_direction?(record.direction) &&
        @connection.allows_lane?(record.lane) && @connection.allows_origin?(binding.canonical_url) &&
        record.topic && record.topic.deleted_at.nil?
    end

    def owned_binding!(resource_id)
      CmsProtocol.validate!("UUID", resource_id)
      binding = scoped_bindings.find_by(discussion_bridge_bridge_records: { resource_id: resource_id })
      CmsProtocol.reject!("resource_not_found") unless binding && binding_available?(binding)
      binding
    end

    def projection(binding)
      record = binding.bridge_record
      CmsProtocol.reject!("resource_not_found") unless binding_available?(binding)
      receipt = record.cms_source_publication if record.direction == "to_discourse"
      mapping = DiscussionBridgeCmsMapping.find_by(content_binding_id: binding.id) if record.direction == "from_discourse"
      state = receipt&.fetch("state", nil) || mapping&.mapping_state ||
        (record.state == "healthy" ? "active" : "attention")
      body = {
        "resource_id" => record.resource_id,
        "direction" => record.direction,
        "state" => state,
        "topic_id" => record.topic_id.to_s,
        "topic_url" => record.topic.url,
        "external_id" => binding.external_id,
        "canonical_url" => binding.canonical_url,
        "source_revision" => receipt&.fetch("revision", nil) || mapping&.desired_source_revision,
        "source_created_at" => receipt&.fetch("created_at", nil) || CmsProtocol.instant(mapping&.source_created_at),
        "source_updated_at" => receipt&.fetch("updated_at", nil) || CmsProtocol.instant(mapping&.source_updated_at),
        "synchronized_at" => receipt&.fetch("synchronized_at", nil) || CmsProtocol.instant(mapping&.synchronized_at),
        "mapping_id" => mapping&.mapping_id,
      }
      CmsProtocol.validate!("Record", body)
      body
    end

    private

    def report_content_loss!(input, error, logger: Rails.logger)
      source = input.fetch("bridge_record")
      log_content_loss!(error, external_id: source.fetch("external_id"),
        source_revision: source.fetch("source_revision"), correlation_id: source["correlation_id"],
        mutation_id: input.fetch("mutation_id"), logger: logger)
    end

    def log_content_loss!(error, external_id:, source_revision:, mutation_id:, correlation_id: nil, resource_id: nil, logger: Rails.logger)
      return unless error.is_a?(PortableContent::PreparationUnavailable)
      observed = error.is_a?(NativeContentPreservation::Loss)
      losses = observed ? error.losses : [{ "kind" => error.diagnostic_code, "element" => nil, "attribute" => nil, "count" => 1 }]
      # Protected native server log; no program/data bodies, values/hashes,
      # URLs, credentials or request trees enter this diagnostic event.
      event = {
        event: "discussion_bridge_native_content_loss",
        connection_id: @connection.public_id,
        external_id: external_id,
        source_revision: source_revision,
        correlation_id: correlation_id,
        mutation_id: mutation_id,
        diagnostic_kind: observed ? error.diagnostic_kind : "article_unavailable",
        losses: losses,
      }
      event[:resource_id] = resource_id if resource_id
      logger.warn(JSON.generate(event))
    end

    # Original accepted replay is classified using its durable receipt. New admissions are fully typed
    # inside the current-authority transaction before any source/native write.
    def validate_resolve_envelope!(input)
      fields = CmsProtocol::SCHEMA.fetch("types").fetch("ToResolve").fetch("fields")
      unless input.is_a?(Hash) && fields.keys.all? { |key| input.key?(key) } && input["bridge_record"].is_a?(Hash)
        CmsProtocol.reject!("invalid_field")
      end
      CmsProtocol.reject!("unknown_field") if (input.keys - fields.keys).any?
      CmsProtocol.validate!("UUID", input.fetch("mutation_id"))
    end

    def transaction
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest &&
             !ActiveSupport::SecurityUtils.secure_compare(@connection.secret_digest, @authenticated_secret_digest)
          CmsProtocol.reject!("authentication_failed")
        end
        CmsConfiguration.current!(@connection, required_direction: nil)
        CmsProtocol.reject!("scope_denied") unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
        yield
      end
    end

    def mutation(route, path, input)
      transaction do
        keys = { content_connection_id: @connection.id, route: route, path_resource: path,
                 mutation_id: input.fetch("mutation_id") }
        if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
          unless CmsReceiptCipher.decrypt(receipt.request_tree) == input
            CmsProtocol.reject!("mutation_conflict")
          end
          body = CmsReceiptCipher.decrypt(receipt.response_body)
          owned_binding!(body.fetch("resource_id")) if body["resource_id"]
          next Result.new(status: receipt.response_status, body: body)
        end
        result = yield
        DiscussionBridgeCmsMutationReceipt.create!(
          **keys, request_tree: CmsReceiptCipher.encrypt(input), response_status: result.status,
          response_body: CmsReceiptCipher.encrypt(result.body),
        )
        result
      end
    end

    def scope_source!(source, effective_lane)
      unless @connection.allows_direction?("to_discourse") &&
               @connection.allows_lane?(effective_lane) && @connection.allows_origin?(source.fetch("canonical_url"))
        CmsProtocol.reject!("scope_denied")
      end
    end

    # Check the global retained URL owner before native creation or revision.
    # The caller holds the same advisory lock through receipt and binding commit.
    def preflight_url!(binding, canonical)
      row = DiscussionBridgeCmsUrlReservation.lock.find_by(
        collision_key_sha256: CmsUrlReservation.collision_digest(canonical),
      )
      if row && (!binding || row.content_binding_id != binding.id || row.cms_mapping_id ||
          row.state != "active" || row.canonical_url != canonical)
        CmsProtocol.reject!("url_collision")
      end
      CmsUrlReservation.new.send(:reject_binding_collision!, CmsUrlReservation.collision_key(canonical),
        allowed_binding_id: binding&.id)
    end

    def policy(data)
      SourceAuthorship.observe!(connection: @connection, source_authors: data[:source_authors])
      authorship = SourceAuthorship.resolve(connection: @connection, request: data)
      CmsProtocol.reject!("scope_denied") unless authorship.allowed?
      actor = User.find_by(username_lower: SiteSetting.discussion_bridge_service_username.downcase)
      lane = LanePolicies.resolve(value: SiteSetting.discussion_bridge_lane_policies, lane: data[:lane])
      authority = ForumAuthority.call(
        actor: actor, category_id: lane.category_id || @connection.default_category_id || SiteSetting.discussion_bridge_effective_category_id,
        tags: lane.tags || SiteSetting.discussion_bridge_effective_tags,
      ) if actor
      PolicyEvaluator.call(
        request: { connection_id: @connection.public_id, source_url: data.fetch(:canonical_url),
                   visibility: data.fetch(:visibility, "unlisted"), lane: data[:lane] },
        settings: PolicyEvaluator::Settings.new(
          enabled: SiteSetting.discussion_bridge_enabled, endpoint_enabled: SiteSetting.discussion_bridge_endpoint_enabled,
          connection_id: @connection.public_id, trusted_origins: @connection.allowed_origins,
          service_username: SiteSetting.discussion_bridge_service_username,
        ), actor: actor, author: authorship.author, authority: authority, lane_resolution: lane,
      )
    end

    def conflict(reason)
      response("ResolveResult", {
        "outcome" => "reconciliation_required", "reason" => reason, "resource_id" => nil,
        "topic_id" => nil, "topic_url" => nil, "direction" => "to_discourse",
        "source_revision" => nil, "synchronized_at" => nil, "core_fallback" => false,
      }, 409)
    end

    def response(type, body, status = 200)
      CmsProtocol.validate!(type, body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > 262_144
      Result.new(status: status, body: body)
    end
  end
end

