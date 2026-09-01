# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class FromDiscourseRecordCreator
    Result = Data.define(:record, :outcome)

    def self.call(user:, connection_id:, topic_id:, external_id:, canonical_url:, native_materialization: false)
      new(
        user: user,
        connection_id: connection_id,
        topic_id: topic_id,
        external_id: external_id,
        canonical_url: canonical_url,
        native_materialization: native_materialization,
      ).call
    end

    def initialize(user:, connection_id:, topic_id:, external_id:, canonical_url:, native_materialization:)
      @user = user
      @connection_id = connection_id
      @topic_id = topic_id
      @external_id = external_id
      @canonical_url = canonical_url
      @native_materialization = native_materialization
    end

    def call
      raise ArgumentError, "invalid native_materialization" unless [true, false].include?(@native_materialization)
      raise ArgumentError, "invalid external_id" unless
        DiscussionBridgeContentBinding.valid_external_id?(@external_id)

      result = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection = DiscussionBridgeContentConnection.lock.find(@connection_id)
        raise ArgumentError, "connection does not permit From Discourse" unless
          connection.enabled && connection.allows_direction?("from_discourse")

        topic = Topic.lock.find(@topic_id)
        raise Discourse::InvalidAccess unless Guardian.new(@user).can_see?(topic)
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

        if bindings.any?
          binding = bindings.one? ? bindings.first : nil
          valid = binding && binding.content_connection_id == connection.id &&
            binding.role == "presentation" && binding.state == "active" &&
            binding.external_id == @external_id && binding.canonical_url == canonical.source_url &&
            binding.native_materialization == @native_materialization &&
            binding.bridge_record.direction == "from_discourse" &&
            binding.bridge_record.topic_id == topic.id
          raise ArgumentError, "binding identity conflict" unless valid

          result = Result.new(record: binding.bridge_record, outcome: "resolved")
          next
        end

        record = DiscussionBridgeBridgeRecord.create!(
          resource_id: SecureRandom.uuid,
          direction: "from_discourse",
          state: "healthy",
          title: topic.title,
          topic_id: topic.id,
          effective_actor_id: topic.user_id,
          requested_visibility: topic.visible ? "listed" : "unlisted",
          effective_visibility: topic.visible ? "listed" : "unlisted",
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
  end
end
