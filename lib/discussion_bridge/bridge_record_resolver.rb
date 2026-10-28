# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class BridgeRecordResolver
    Result =
      Data.define(
        :outcome,
        :reason,
        :resource_id,
        :topic_id,
        :topic_url,
        :direction,
        :source_revision,
        :source_publication_outcome,
      )

    def self.call(connection:, request:, policy:, topic_creator: TopicCreator.new, after_commit: nil)
      new(
        connection: connection,
        request: request,
        policy: policy,
        topic_creator: topic_creator,
        after_commit: after_commit,
      ).call
    end

    def initialize(connection:, request:, policy:, topic_creator:, after_commit: nil)
      @connection = connection
      @request = request
      @policy = policy
      @topic_creator = topic_creator
      @after_commit = after_commit || ->(creation) { @topic_creator.after_commit(creation) }
    end

    def call
      return result("rejected", @policy.reason) unless @policy.allowed

      canonical =
        CanonicalSource.call(
          connection_id: @connection.public_id,
          source_url: @request.fetch(:canonical_url),
        )
      identity_digest =
        Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@request.fetch(:external_id)}")
      url_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{canonical.source_url}")
      creation = nil
      bridge_record = nil
      adopted_topic = nil

      DiscussionBridgeBridgeRecord.transaction do
        @connection.lock!
        unless @connection.enabled && @connection.allows_direction?(@request[:direction]) &&
                 @connection.allows_lane?(@request[:lane]) &&
                 @connection.allows_origin?(@request[:canonical_url])
          return result("rejected", "connection_scope_denied")
        end
        matches =
          DiscussionBridgeContentBinding
            .lock
            .where(
              "identity_digest = :identity OR canonical_url_digest = :url",
              identity: identity_digest,
              url: url_digest,
            )
            .to_a
        return resolve_existing(matches, canonical, identity_digest, url_digest) if matches.any?

        if @request[:source_publication]&.fetch("previous_revision")
          return result("reconciliation_required", "source_publication_missing")
        end

        adopted_topic = adoptable_core_embed_topic(canonical) if @request[:existing_topic_id]
        if adopted_topic && @request[:source_publication] &&
             !@topic_creator.matches_source?(
               topic: adopted_topic,
               first_post: adopted_topic.first_post,
               request: topic_request(canonical),
               policy: @policy,
             )
          return result("reconciliation_required", "source_publication_adoption_conflict")
        end

        bridge_record =
          DiscussionBridgeBridgeRecord.create!(
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
            reservation_token: adopted_topic ? nil : SecureRandom.hex(32),
          )
        DiscussionBridgeContentBinding.create!(
          bridge_record: bridge_record,
          content_connection: @connection,
          role: "source",
          state: "active",
          external_id: @request.fetch(:external_id),
          canonical_url: canonical.source_url,
          identity_digest: identity_digest,
          canonical_url_digest: url_digest,
          activated_at: Time.zone.now,
        )
        unless adopted_topic
          creation = @topic_creator.call(request: topic_request(canonical), policy: @policy)
          bridge_record.update!(
            topic_id: creation.topic.id,
            state: "healthy",
            reservation_token: nil,
          )
        end
        if @request[:source_publication]
          bridge_record.update!(CmsToPublication.attributes(
            @request[:source_publication], @request, bridge_record.topic, bridge_record.topic.first_post,
          ))
          @source_publication_outcome = adopted_topic ? "adopted" : "created"
        end
        write_audit!(
          bridge_record,
          identity_digest,
          "created",
          adopted_topic ? "core_embed_topic_adopted" : "bridge_record_created",
        )
      end
      update_connection_presence!
      @after_commit.call(creation) if creation
      result(
        "created",
        adopted_topic ? "core_embed_topic_adopted" : "bridge_record_created",
        bridge_record,
      )
    rescue ActiveRecord::RecordNotUnique
      retry_existing
    end

    private

    def adoptable_core_embed_topic(canonical)
      topic_id = @request.fetch(:existing_topic_id)
      if DiscussionBridgeBridgeRecord.exists?(topic_id: topic_id)
        raise ArgumentError, "existing topic already has a DiscussionBridge mapping"
      end
      unless TopicEmbed.topic_id_for_embed(canonical.source_url) == topic_id
        raise ArgumentError,
              "existing topic is not the Discourse Core embed for this canonical source"
      end

      topic = Topic.unscoped.lock.find_by(id: topic_id)
      unless topic && topic.deleted_at.nil? && topic.visible == false &&
               Post.unscoped.exists?(topic_id: topic.id, post_number: 1, deleted_at: nil)
        raise ArgumentError, "existing Core embed topic is unavailable"
      end
      topic
    end

    def retry_existing
      canonical =
        CanonicalSource.call(
          connection_id: @connection.public_id,
          source_url: @request.fetch(:canonical_url),
        )
      identity_digest =
        Digest::SHA256.hexdigest("#{@connection.public_id}\n#{@request.fetch(:external_id)}")
      url_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{canonical.source_url}")
      DiscussionBridgeBridgeRecord.transaction do
        @connection.lock!
        unless @connection.enabled && @connection.allows_direction?(@request[:direction]) &&
                 @connection.allows_lane?(@request[:lane]) &&
                 @connection.allows_origin?(@request[:canonical_url])
          return result("rejected", "connection_scope_denied")
        end
        matches =
          DiscussionBridgeContentBinding
            .lock
            .where(
              "identity_digest = :identity OR canonical_url_digest = :url",
              identity: identity_digest,
              url: url_digest,
            )
            .to_a
        resolve_existing(matches, canonical, identity_digest, url_digest)
      end
    end

    def resolve_existing(matches, canonical, identity_digest, url_digest)
      binding = matches.one? ? matches.first : nil
      valid =
        binding && binding.content_connection_id == @connection.id &&
          binding.identity_digest == identity_digest &&
          binding.canonical_url_digest == url_digest &&
          binding.external_id == @request.fetch(:external_id) &&
          binding.canonical_url == canonical.source_url && binding.role == "source" &&
          binding.state == "active"
      return result("reconciliation_required", "binding_identity_conflict") unless valid

      record = binding.bridge_record
      if record.respond_to?(:cms_source_publication) && %w[withdrawn attention].include?(record.cms_source_publication&.fetch("state", nil))
        return result("reconciliation_required", "binding_identity_conflict")
      end
      topic = Topic.find_by(id: record.topic_id)
      unless record.direction == "to_discourse" && record.state == "healthy" && topic &&
               topic.deleted_at.nil? &&
               Post.exists?(topic_id: topic.id, post_number: 1, deleted_at: nil)
        return result("reconciliation_required", "bridge_record_unavailable", record)
      end

      if @request[:source_publication]
        record.lock!
        first_post = Post.where(topic_id: topic.id, post_number: 1, deleted_at: nil).lock.first
        topic.reload(lock: true)
        unless first_post && topic.deleted_at.nil?
          return result("reconciliation_required", "bridge_record_unavailable", record)
        end
        incoming = @request.fetch(:source_publication)
        stored = CmsToPublication.read(record)
        return result("reconciliation_required", "source_publication_missing", record) unless stored
        begin
          unless stored["managed_native_sha256"] ==
                   ManagedNativePublication.managed_native_sha256(topic, first_post)
            return result("reconciliation_required", "managed_native_post_changed", record)
          end
          if incoming["revision"] == stored["revision"]
            unless CmsToPublication.same_edition?(stored, incoming, @request)
              return(
                result("reconciliation_required", "source_publication_revision_conflict", record)
              )
            end
            @source_publication_outcome = "unchanged"
          else
            unless incoming["previous_revision"] == stored["revision"]
              return(
                result("reconciliation_required", "source_publication_revision_conflict", record)
              )
            end
            denial = @topic_creator.update_denial(first_post: first_post, policy: @policy)
            return result("rejected", denial, record) if denial
            @topic_creator.update(
              topic: topic,
              first_post: first_post,
              request: topic_request(canonical),
              policy: @policy,
            )
            @source_publication_outcome = "updated"
          end
        end
        if @source_publication_outcome != "unchanged"
          record.update!(
            title: @request.fetch(:title),
            effective_actor_id: first_post.user_id,
            source_authors: Array(@request[:source_authors]),
            primary_source_author_id: @request[:primary_source_author_id],
            **CmsToPublication.attributes(incoming, @request, topic, first_post),
          )
        end
      end

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
        generate_topic_toc: @connection.generate_topic_toc,
        owned_generated_link: @request[:cms_input]&.dig("representation", "kind") == "generated_excerpt",
      }.compact
    end

    def update_connection_presence!
      attributes = { last_seen_at: Time.zone.now, updated_at: Time.zone.now }
      attributes[:adapter_id] = @request[:adapter_id] if @request[:adapter_id].present?
      attributes[:adapter_version] = @request[:adapter_version] if @request[
        :adapter_version
      ].present?
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
        requested_state: {
        },
        effective_state: {
        },
      )
    end

    def result(outcome, reason, record = nil)
      Result.new(
        outcome: outcome,
        reason: reason,
        resource_id: record&.resource_id,
        topic_id: record&.topic_id,
        topic_url: record&.topic&.url,
        direction: record&.direction || @request[:direction],
        source_revision:
          @request[:source_publication] ? (record && CmsToPublication.read(record))&.fetch("revision", nil) : nil,
        source_publication_outcome: @source_publication_outcome,
      )
    end
  end
end
