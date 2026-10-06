# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class BridgeRecordResolver
    Result = Data.define(:outcome, :reason, :resource_id, :topic_id, :topic_url, :direction,
                         :accepted_source_revision, :accepted_source_revision_sequence, :conflict_fields)

    def self.call(connection:, request:, policy:, topic_creator: TopicCreator.new)
      new(connection: connection, request: request, policy: policy, topic_creator: topic_creator).call
    end

    def initialize(connection:, request:, policy:, topic_creator:)
      @connection, @request, @policy, @topic_creator = connection, request, policy, topic_creator
    end

    def call
      raise AdapterRequestBoundary::Error.new("policy_denied") unless @policy.allowed
      @canonical = CanonicalSource.call(connection_id: @connection.public_id, source_url: @request.fetch(:canonical_url))
      @identity_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@request.fetch(:external_id)}")
      @url_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@canonical.source_url}")
      attempts = 0
      begin
        creation = nil
        resolved = DiscussionBridgeBridgeRecord.transaction(requires_new: true) do
          @connection.lock!
          check_scope!
          matches = DiscussionBridgeContentBinding.lock.where(
            "identity_digest = :identity OR canonical_url_digest = :url",
            identity: @identity_digest, url: @url_digest,
          ).to_a
          if matches.any?
            next resolve_existing(matches)
          end
          adopted = adoptable_core_embed_topic if @request[:existing_topic_id]
          record = DiscussionBridgeBridgeRecord.create!(
            resource_id: SecureRandom.uuid, direction: "to_discourse",
            state: adopted ? "healthy" : "reserved", title: @request.fetch(:title),
            topic_id: adopted&.id, effective_actor_id: adopted&.user_id || @policy.effective_actor_id,
            lane: @request[:lane], requested_visibility: @request.fetch(:visibility, "unlisted"),
            effective_visibility: @policy.effective_visibility,
            source_authors: Array(@request[:source_authors]),
            primary_source_author_id: @request[:primary_source_author_id],
            reservation_token: adopted ? nil : SecureRandom.hex(32),
            **source_context(adopted ? "observed" : "applied"),
          )
          binding = DiscussionBridgeContentBinding.create!(
            bridge_record: record, content_connection: @connection,
            public_id: "dbb_#{SecureRandom.hex(16)}", role: "source", state: "active",
            external_id: @request.fetch(:external_id), canonical_url: @canonical.source_url,
            identity_digest: @identity_digest, canonical_url_digest: @url_digest,
            activated_at: Time.zone.now, presentation_mode: @request.fetch(:presentation_mode),
            content_disposition: @request.fetch(:content_disposition), read_more_url: @request[:read_more_url],
          )
          unless adopted
            begin
              creation = @topic_creator.call(request: topic_request, policy: @policy)
            rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Discourse::InvalidParameters
              raise AdapterRequestBoundary::Error.new("content_unsupported")
            end
            record.update!(topic_id: creation.topic.id, state: "healthy", reservation_token: nil)
            applied_binding!(binding, record)
          end
          reason = adopted ? "core_embed_topic_adopted" : "bridge_record_created"
          write_audit!(record, "created", reason)
          update_connection_presence!
          result("created", reason, record)
        end
        ActiveRecord.after_all_transactions_commit { @topic_creator.after_commit(creation) } if creation
        resolved
      rescue ActiveRecord::RecordNotUnique
        # A concurrent insert is re-read inside a new locked transaction. Never
        # accept an unlocked identity lookup after a failed PostgreSQL write.
        attempts += 1
        retry if attempts == 1
        result("reconciliation_required", "binding_identity_conflict", nil, %w[external_id canonical_url])
      end
    end

    private

    def check_scope!
      raise AdapterRequestBoundary::Error.new("temporarily_unavailable") unless
        SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled && @connection.enabled
      raise AdapterRequestBoundary::Error.new("direction_denied") unless @connection.allows_direction?(@request[:direction])
      unless @connection.allows_lane?(@request[:lane]) && @connection.allows_origin?(@request[:canonical_url])
        raise AdapterRequestBoundary::Error.new("scope_denied")
      end
    end

    def adoptable_core_embed_topic
      topic_id = @request.fetch(:existing_topic_id)
      topic = Topic.unscoped.lock.find_by(id: topic_id)
      post = Post.unscoped.lock.find_by(topic_id: topic_id, post_number: 1, deleted_at: nil)
      mapped = DiscussionBridgeBridgeRecord.exists?(topic_id: topic_id) || DiscussionBridgeConnection.exists?(topic_id: topic_id)
      unless topic && post && !mapped && topic.deleted_at.nil? && topic.visible == false &&
          TopicEmbed.topic_id_for_embed(@canonical.source_url) == topic_id
        raise AdapterRequestBoundary::Error.new("reconciliation_required")
      end
      # No Topic/Post updater, title assignment, owner change or revision here.
      topic
    end

    def resolve_existing(matches)
      binding = matches.one? ? matches.first : nil
      valid = binding && binding.content_connection_id == @connection.id &&
        binding.identity_digest == @identity_digest && binding.canonical_url_digest == @url_digest &&
        binding.external_id == @request.fetch(:external_id) && binding.canonical_url == @canonical.source_url &&
        binding.role == "source" && binding.state == "active"
      return result("reconciliation_required", "binding_identity_conflict", nil, %w[external_id canonical_url]) unless valid
      record = DiscussionBridgeBridgeRecord.lock.find(binding.bridge_record_id)
      unless record.direction == "to_discourse" && record.state == "healthy" && record.known_source_context? && binding.public_id
        return result("reconciliation_required", "source_revision_context_unknown", record, %w[source_revision])
      end
      if @request[:existing_topic_id] && @request[:existing_topic_id] != record.topic_id
        return result("reconciliation_required", "topic_identity_conflict", record, %w[existing_topic_id])
      end
      if record.source_created_at_raw != @request[:source_created_at] || record.lane != @request[:lane]
        return result("reconciliation_required", "source_identity_conflict", record, %w[source_created_at lane])
      end
      current = record.source_revision_sequence
      incoming = @request.fetch(:source_revision_sequence)
      if incoming < current
        return result("reconciliation_required", "source_revision_stale", record, %w[source_revision_sequence])
      end
      if incoming == current
        unless record.source_request_fingerprint == fingerprint
          return result("reconciliation_required", "source_revision_replay_mismatch", record, %w[source_revision])
        end
      elsif record.source_revision == @request[:source_revision] ||
          BridgeRecordRequest.timestamp!(@request[:source_updated_at]) < BridgeRecordRequest.timestamp!(record.source_updated_at_raw)
        return result("reconciliation_required", "source_revision_conflict", record, %w[source_revision source_updated_at])
      end
      integrity = ExistingMappingIntegrity.call(
        mapping: record, policy: @policy.with(effective_actor_id: record.effective_actor_id), request: @request,
      )
      return result("reconciliation_required", "bridge_record_unavailable", record, %w[topic_id]) unless integrity.usable?
      if incoming > current
        @topic_creator.update(record: record, request: topic_request, policy: @policy)
        record.update!(title: @request.fetch(:title), source_authors: Array(@request[:source_authors]),
                       primary_source_author_id: @request[:primary_source_author_id], **source_context("applied"))
        binding.update!(presentation_mode: @request.fetch(:presentation_mode),
                        content_disposition: @request.fetch(:content_disposition), read_more_url: @request[:read_more_url])
        applied_binding!(binding, record)
      end
      reason = incoming == current ? "existing_bridge_record" : "source_revision_updated"
      write_audit!(record, "resolved", reason)
      update_connection_presence!
      result("resolved", reason, record)
    end

    def source_context(state)
      {
        source_revision: @request.fetch(:source_revision),
        source_revision_sequence: @request.fetch(:source_revision_sequence),
        source_created_at_raw: @request.fetch(:source_created_at),
        source_updated_at_raw: @request.fetch(:source_updated_at),
        source_content_sha256: @request.fetch(:source_content_sha256),
        source_content_bytes: @request.fetch(:source_content_bytes),
        content_disposition: @request.fetch(:content_disposition),
        source_context_state: state, source_request_fingerprint: fingerprint,
      }
    end

    def fingerprint
      fields = @request.except(:correlation_id, :adapter_id, :adapter_version, :existing_topic_id)
      ordered = fields.sort_by { |key, _| key.to_s }.to_h
      Digest::SHA256.hexdigest(JSON.generate(ordered))
    end

    def applied_binding!(binding, record)
      post = record.topic.first_post.reload
      binding.update!(applied_source_revision: record.source_revision,
                      publication_revision: "post:#{post.id}:version:#{post.version}",
                      synchronized_at_raw: Time.now.utc.iso8601(6))
    end

    def topic_request
      {
        connection_id: @connection.public_id, source_url: @canonical.source_url,
        title: @request.fetch(:title), content_html: @request.fetch(:content_html),
        lane: @request[:lane], visibility: @request.fetch(:visibility, "unlisted"),
        adapter_id: @request[:adapter_id], correlation_id: @request[:correlation_id],
        source_authors: Array(@request[:source_authors]), primary_source_author_id: @request[:primary_source_author_id],
        generate_topic_toc: @connection.generate_topic_toc,
      }.compact
    end

    def update_connection_presence!
      values = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
      values[:adapter_id] = @request[:adapter_id] if @request[:adapter_id]
      values[:adapter_version] = @request[:adapter_version] if @request[:adapter_version]
      @connection.update_columns(values)
    end

    def write_audit!(record, outcome, reason)
      DiscussionBridgeAuditEvent.create!(
        correlation_id: @request[:correlation_id], connection_id: @connection.public_id,
        adapter_id: @request[:adapter_id] || @connection.adapter_id,
        source_identity_digest: @identity_digest, topic_id: record&.topic_id,
        effective_actor_id: record&.effective_actor_id, outcome: outcome, reason: reason,
        requested_state: {}, effective_state: {},
      )
    end

    def result(outcome, reason, record = nil, conflicts = nil)
      Result.new(outcome: outcome, reason: reason, resource_id: record&.resource_id,
                 topic_id: record&.topic_id, topic_url: record&.topic&.url,
                 direction: record&.direction || @request[:direction],
                 accepted_source_revision: record&.source_revision,
                 accepted_source_revision_sequence: record&.source_revision_sequence, conflict_fields: conflicts)
    end
  end
end
