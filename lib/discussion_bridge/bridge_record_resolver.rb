# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class BridgeRecordResolver
    Result = Data.define(
      :outcome,
      :reason,
      :resource_id,
      :topic_id,
      :topic_url,
      :direction,
      :accepted_source_revision,
      :accepted_source_revision_sequence,
      :conflict_fields,
    )

    def self.call(connection:, request:, policy:, topic_creator: TopicCreator.new)
      new(connection: connection, request: request, policy: policy, topic_creator: topic_creator).call
    end

    def initialize(connection:, request:, policy:, topic_creator:)
      @connection = connection
      @request = request
      @policy = policy
      @topic_creator = topic_creator
    end

    def call
      return result("rejected", @policy.reason) unless @policy.allowed

      canonical = CanonicalSource.call(
        connection_id: @connection.public_id,
        source_url: @request.fetch(:canonical_url),
      )
      identity_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@request.fetch(:external_id)}")
      url_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{canonical.source_url}")
      creation = nil
      bridge_record = nil
      adopted_topic = nil

      DiscussionBridgeBridgeRecord.transaction do
        @connection.lock!
        unless @connection.enabled && @connection.allows_direction?(@request[:direction]) &&
            @connection.allows_lane?(@request[:lane]) && @connection.allows_origin?(@request[:canonical_url])
          return result("rejected", "connection_scope_denied")
        end
        matches = DiscussionBridgeContentBinding.lock.where(
          "identity_digest = :identity OR canonical_url_digest = :url",
          identity: identity_digest,
          url: url_digest,
        ).to_a
        if matches.any?
          return resolve_existing(matches, canonical, identity_digest, url_digest)
        end
        UrlReservation.ensure_available!(
          connection: @connection,
          canonical_url: canonical.source_url,
        )

        adopted_topic = adoptable_core_embed_topic(canonical) if @request[:existing_topic_id]

        bridge_record = DiscussionBridgeBridgeRecord.create!(
          resource_id: SecureRandom.uuid,
          direction: "to_discourse",
          state: adopted_topic ? "healthy" : "reserved",
          title: @request.fetch(:title),
          topic_id: adopted_topic&.id,
          effective_actor_id: adopted_topic&.user_id || @policy.effective_actor_id,
          lane: @request[:lane],
          requested_visibility: @request.fetch(:visibility, "unlisted"),
          effective_visibility: @policy.effective_visibility,
          source_authors: Array(@request[:source_authors]),
          primary_source_author_id: @request[:primary_source_author_id],
          presentation_mode: @request.fetch(:presentation_mode),
          source_revision: @request.fetch(:source_revision),
          source_revision_sequence: @request.fetch(:source_revision_sequence),
          source_created_at: @request.fetch(:source_created_at),
          source_updated_at: @request.fetch(:source_updated_at),
          content_disposition: @request.fetch(:content_disposition),
          source_content_bytes: @request.fetch(:source_content_bytes),
          source_content_sha256: @request.fetch(:source_content_sha256),
          delivered_content_sha256: Digest::SHA256.hexdigest(@request.fetch(:content_html)),
          reservation_token: adopted_topic ? nil : SecureRandom.hex(32),
        )
        binding = DiscussionBridgeContentBinding.create!(
          bridge_record: bridge_record,
          content_connection: @connection,
          role: "source",
          state: "active",
          external_id: @request.fetch(:external_id),
          canonical_url: canonical.source_url,
          identity_digest: identity_digest,
          canonical_url_digest: url_digest,
          activated_at: Time.zone.now,
          presentation_mode: @request.fetch(:presentation_mode),
          applied_source_revision: @request.fetch(:source_revision),
          content_disposition: @request.fetch(:content_disposition),
          synchronized_at: Time.zone.now,
        )
        if adopted_topic
          @topic_creator.update(
            request: topic_request(canonical),
            policy: @policy,
            record: bridge_record,
          )
        else
          creation = @topic_creator.call(request: topic_request(canonical), policy: @policy)
          bridge_record.update!(
            topic_id: creation.topic.id,
            state: "healthy",
            reservation_token: nil,
          )
        end
        binding.update!(publication_revision: topic_revision(bridge_record.topic))
        write_audit!(
          bridge_record,
          identity_digest,
          "created",
          adopted_topic ? "core_embed_topic_adopted" : "bridge_record_created",
        )
      end
      update_connection_presence!
      @topic_creator.after_commit(creation) if creation
      result("created", adopted_topic ? "core_embed_topic_adopted" : "bridge_record_created", bridge_record)
    rescue ActiveRecord::RecordNotUnique
      retry_existing
    end

    private

    def adoptable_core_embed_topic(canonical)
      topic_id = @request.fetch(:existing_topic_id)
      if DiscussionBridgeBridgeRecord.exists?(topic_id: topic_id) ||
          (defined?(DiscussionBridgeConnection) && DiscussionBridgeConnection.exists?(topic_id: topic_id))
        raise ArgumentError, "existing topic already has a DiscussionBridge mapping"
      end
      unless TopicEmbed.topic_id_for_embed(canonical.source_url) == topic_id
        raise ArgumentError, "existing topic is not the Discourse Core embed for this canonical source"
      end

      topic = Topic.unscoped.lock.find_by(id: topic_id)
      unless topic && topic.deleted_at.nil? && topic.visible == false &&
          Post.unscoped.exists?(topic_id: topic.id, post_number: 1, deleted_at: nil)
        raise ArgumentError, "existing Core embed topic is unavailable"
      end
      topic
    end

    def retry_existing
      canonical = CanonicalSource.call(connection_id: @connection.public_id, source_url: @request.fetch(:canonical_url))
      identity_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@request.fetch(:external_id)}")
      url_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{canonical.source_url}")
      matches = DiscussionBridgeContentBinding.where(
        "identity_digest = :identity OR canonical_url_digest = :url",
        identity: identity_digest,
        url: url_digest,
      ).to_a
      resolve_existing(matches, canonical, identity_digest, url_digest)
    end

    def resolve_existing(matches, canonical, identity_digest, url_digest)
      binding = matches.one? ? matches.first : nil
      valid = binding && binding.content_connection_id == @connection.id &&
        binding.identity_digest == identity_digest && binding.canonical_url_digest == url_digest &&
        binding.external_id == @request.fetch(:external_id) && binding.canonical_url == canonical.source_url &&
        binding.role == "source" && binding.state == "active"
      return result(
        "reconciliation_required",
        "binding_identity_conflict",
        nil,
        %w[external_id canonical_url],
      ) unless valid

      record = binding.bridge_record
      if @request[:existing_topic_id].present? && @request[:existing_topic_id] != record.topic_id
        return result("reconciliation_required", "binding_identity_conflict", record, ["existing_topic_id"])
      end
      topic = Topic.find_by(id: record.topic_id)
      unless record.direction == "to_discourse" && record.state == "healthy" && topic &&
          topic.deleted_at.nil? && Post.exists?(topic_id: topic.id, post_number: 1, deleted_at: nil)
        return result("reconciliation_required", "bridge_record_unavailable", record, ["topic_id"])
      end

      apply_revision!(record, binding)

      update_connection_presence!
      write_audit!(record, identity_digest, "resolved", "existing_bridge_record")
      result("resolved", "existing_bridge_record", record)
    end

    def topic_request(canonical)
      {
        connection_id: @connection.public_id,
        source_url: canonical.source_url,
        title: @request.fetch(:title),
        content_html: @request.fetch(:content_html),
        lane: @request[:lane],
        visibility: @request.fetch(:visibility, "unlisted"),
        adapter_id: @request[:adapter_id],
        correlation_id: @request[:correlation_id],
        source_authors: Array(@request[:source_authors]),
        primary_source_author_id: @request[:primary_source_author_id],
        source_revision: @request.fetch(:source_revision),
        generate_topic_toc: @connection.generate_topic_toc,
      }.compact
    end

    def update_connection_presence!
      attributes = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
      attributes[:adapter_id] = @request[:adapter_id] if @request[:adapter_id].present?
      attributes[:adapter_version] = @request[:adapter_version] if @request[:adapter_version].present?
      @connection.update_columns(attributes)
    end

    def write_audit!(record, digest, outcome, reason)
      DiscussionBridgeAuditEvent.create!(
        correlation_id: @request[:correlation_id],
        connection_id: @connection.public_id,
        adapter_id: @request[:adapter_id] || @connection.adapter_id,
        source_identity_digest: digest,
        topic_id: record&.topic_id,
        effective_actor_id: record&.effective_actor_id,
        outcome: outcome,
        reason: reason,
        requested_state: {},
        effective_state: {},
      )
    end

    def apply_revision!(record, binding)
      status = revision_status(record)
      return if status == :replay

      first_post = @topic_creator.update(
        request: topic_request(
          CanonicalSource.call(
            connection_id: @connection.public_id,
            source_url: @request.fetch(:canonical_url),
          ),
        ),
        policy: @policy,
        record: record,
      )
      record.update!(revision_attributes.merge(title: @request.fetch(:title)))
      binding.update!(
        presentation_mode: @request.fetch(:presentation_mode),
        applied_source_revision: @request.fetch(:source_revision),
        publication_revision: "post:#{first_post.id}:version:#{first_post.version}",
        content_disposition: @request.fetch(:content_disposition),
        synchronized_at: Time.zone.now,
      )
    end

    def revision_status(record)
      return :update if record.source_revision.blank? || record.source_revision_sequence.blank?

      requested_sequence = @request.fetch(:source_revision_sequence)
      stored_sequence = record.source_revision_sequence
      raise AdapterRequestBoundary::Error, "revision_conflict" if requested_sequence < stored_sequence

      if requested_sequence == stored_sequence
        raise AdapterRequestBoundary::Error, "revision_conflict" unless exact_replay?(record)

        return :replay
      end

      if @request.fetch(:source_revision) == record.source_revision ||
          @request.fetch(:source_created_at) != record.source_created_at ||
          @request[:lane].to_s != record.lane.to_s
        raise AdapterRequestBoundary::Error, "revision_conflict"
      end

      :update
    end

    def exact_replay?(record)
      record.source_revision == @request.fetch(:source_revision) &&
        record.source_created_at == @request.fetch(:source_created_at) &&
        record.source_updated_at == @request.fetch(:source_updated_at) &&
        record.source_content_bytes == @request.fetch(:source_content_bytes) &&
        record.source_content_sha256 == @request.fetch(:source_content_sha256) &&
        record.delivered_content_sha256 == Digest::SHA256.hexdigest(@request.fetch(:content_html)) &&
        record.content_disposition == @request.fetch(:content_disposition) &&
        record.presentation_mode == @request.fetch(:presentation_mode) &&
        record.title == @request.fetch(:title) &&
        record.lane.to_s == @request[:lane].to_s &&
        record.requested_visibility == @request.fetch(:visibility, "unlisted") &&
        record.source_authors == Array(@request[:source_authors]).map(&:stringify_keys) &&
        record.primary_source_author_id == @request[:primary_source_author_id]
    end

    def revision_attributes
      {
        presentation_mode: @request.fetch(:presentation_mode),
        source_revision: @request.fetch(:source_revision),
        source_revision_sequence: @request.fetch(:source_revision_sequence),
        source_created_at: @request.fetch(:source_created_at),
        source_updated_at: @request.fetch(:source_updated_at),
        content_disposition: @request.fetch(:content_disposition),
        source_content_bytes: @request.fetch(:source_content_bytes),
        source_content_sha256: @request.fetch(:source_content_sha256),
        delivered_content_sha256: Digest::SHA256.hexdigest(@request.fetch(:content_html)),
        source_authors: Array(@request[:source_authors]),
        primary_source_author_id: @request[:primary_source_author_id],
      }
    end

    def topic_revision(topic)
      post = topic&.first_post
      post ? "post:#{post.id}:version:#{post.version}" : nil
    end

    def result(outcome, reason, record = nil, conflict_fields = nil)
      Result.new(
        outcome: outcome,
        reason: reason,
        resource_id: record&.resource_id,
        topic_id: record&.topic_id,
        topic_url: record&.topic&.url,
        direction: record&.direction || @request[:direction],
        accepted_source_revision: outcome == "reconciliation_required" ? nil : @request[:source_revision],
        accepted_source_revision_sequence: outcome == "reconciliation_required" ? nil : @request[:source_revision_sequence],
        conflict_fields: conflict_fields,
      )
    end
  end
end
