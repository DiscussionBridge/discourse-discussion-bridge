# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class FromDiscourseRecordCreator
    Result = Data.define(:record, :outcome)

    def self.call(user:, connection_id:, topic_id:, external_id:, canonical_url:, lane: nil, native_materialization: false)
      new(
        user: user,
        connection_id: connection_id,
        topic_id: topic_id,
        external_id: external_id,
        canonical_url: canonical_url,
        lane: lane,
        native_materialization: native_materialization,
      ).call
    end

    def self.call_for_connection(connection:, topic_id:, expected_source_revision:, external_id:,
                                 canonical_url:, lane: nil, native_materialization: false)
      new(
        user: nil,
        connection_id: connection.id,
        topic_id: topic_id,
        external_id: external_id,
        canonical_url: canonical_url,
        lane: lane,
        native_materialization: native_materialization,
        expected_source_revision: expected_source_revision,
        public_connection_id: connection.id,
        publication_program: "forum_sync",
      ).call
    end

    def initialize(user:, connection_id:, topic_id:, external_id:, canonical_url:, lane:, native_materialization:,
                   expected_source_revision: nil, public_connection_id: nil, publication_program: "legacy")
      @user = user
      @connection_id = connection_id
      @topic_id = topic_id
      @external_id = external_id
      @canonical_url = canonical_url
      @lane = lane
      @native_materialization = native_materialization
      @expected_source_revision = expected_source_revision
      @public_connection_id = public_connection_id
      @publication_program = publication_program
    end

    def call
      raise ArgumentError, "invalid native_materialization" if [true, false].exclude?(@native_materialization)
      raise ArgumentError, "invalid external_id" unless
        DiscussionBridgeContentBinding.valid_external_id?(@external_id)

      result = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection = DiscussionBridgeContentConnection.lock.find(@connection_id)
        raise ArgumentError, "connection does not permit From Discourse" unless
          connection.enabled && connection.allows_direction?("from_discourse")
        lane = resolved_lane(connection)

        topic = Topic.lock.find(@topic_id)
        if @public_connection_id
          raise ArgumentError, "connection changed" unless connection.id == @public_connection_id
          topic = PublicationTopicScope.find!(connection, topic.id)
          first_post = topic.first_post
          first_post.lock!
          raise ArgumentError, "source revision changed" unless
            @expected_source_revision == PublicationTopicScope.revision(topic, post: first_post.reload)
        else
          raise Discourse::InvalidAccess unless Guardian.new(@user).can_see?(topic)
        end
        raise ArgumentError, "topic is unavailable" if
          topic.deleted_at || topic.first_post.nil? || topic.first_post.deleted_at

        canonical = CanonicalSource.call(
          connection_id: connection.public_id,
          source_url: @canonical_url,
        )
        raise ArgumentError, "origin is outside connection scope" unless
          connection.allows_origin?(canonical.source_url)

        identity_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{@external_id}")
        canonical_url_digest = Digest::SHA256.hexdigest(
          "#{connection.public_id}\n#{canonical.source_url}",
        )
        bindings = DiscussionBridgeContentBinding.lock.where(
          "identity_digest = :identity OR canonical_url_digest = :url",
          identity: identity_digest,
          url: canonical_url_digest,
        ).to_a
        retired_url = DiscussionBridgePresentationUrlHistory.where(
          old_canonical_url_digest: canonical_url_digest,
        )
        retired_source_url = DiscussionBridgeSourceUrlHistory.where(
          old_canonical_url_digest: canonical_url_digest,
        )
        if retired_url.exists? || retired_source_url.exists?
          current_owner = bindings.one? && bindings.first.state == "active" &&
            bindings.first.canonical_url_digest == canonical_url_digest &&
            !retired_url.where.not(content_binding_id: bindings.first.id).exists? &&
            !retired_source_url.exists?
          raise ArgumentError, "publication URL is reserved by migration history" unless current_owner
        end

        if bindings.any?
          binding = bindings.one? ? bindings.first : nil
          valid = binding && binding.content_connection_id == connection.id &&
            binding.role == "presentation" && binding.state == "active" &&
            binding.external_id == @external_id && binding.canonical_url == canonical.source_url &&
            binding.native_materialization == @native_materialization &&
            binding.bridge_record.direction == "from_discourse" &&
            binding.bridge_record.lane.to_s == lane.to_s &&
            binding.bridge_record.topic_id == topic.id
          raise ArgumentError, "binding identity conflict" unless valid

          record = binding.bridge_record
          if @publication_program == "forum_sync" && record.publication_program == "legacy"
            record.update!(publication_program: "forum_sync_pending")
          end
          valid_program = record.publication_program == @publication_program ||
            (@publication_program == "forum_sync" && record.publication_program == "forum_sync_pending")
          raise ArgumentError, "publication program conflict" unless valid_program
          visibility = topic.visible ? "listed" : "unlisted"
          record.update!(
            title: topic.title,
            effective_actor_id: topic.user_id,
            requested_visibility: visibility,
            effective_visibility: visibility,
          )
          result = Result.new(record: record, outcome: "resolved")
          next
        end


        existing_publication = DiscussionBridgeBridgeRecord.joins(:content_bindings).lock
          .where(direction: "from_discourse", topic_id: topic.id)
          .where(discussion_bridge_content_bindings: {
            content_connection_id: connection.id, role: "presentation", state: "active",
          }).first
        raise ArgumentError, "publication identity changed; migration required" if existing_publication

        record = DiscussionBridgeBridgeRecord.create!(
          resource_id: SecureRandom.uuid,
          direction: "from_discourse",
          lane: lane,
          state: "healthy",
          title: topic.title,
          topic_id: topic.id,
          effective_actor_id: topic.user_id,
          requested_visibility: topic.visible ? "listed" : "unlisted",
          effective_visibility: topic.visible ? "listed" : "unlisted",
          destination_state: @public_connection_id ? "pending" : nil,
          publication_program: @publication_program,
        )
        DiscussionBridgeContentBinding.create!(
          bridge_record: record,
          content_connection: connection,
          role: "presentation",
          state: "active",
          external_id: @external_id,
          canonical_url: canonical.source_url,
          identity_digest: identity_digest,
          canonical_url_digest: canonical_url_digest,
          native_materialization: @native_materialization,
          activated_at: Time.zone.now,
        )
        result = Result.new(record: record, outcome: "created")
      end
      result
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    def resolved_lane(connection)
      requested = @lane.to_s.presence
      allowed = Array(connection.allowed_lanes)
      resolved = requested || (allowed.one? ? allowed.first : nil)
      raise ArgumentError, "lane is required for this connection" if resolved.nil? && allowed.many?
      raise ArgumentError, "lane is outside connection scope" unless connection.allows_lane?(resolved)

      resolved
    end
  end
end
