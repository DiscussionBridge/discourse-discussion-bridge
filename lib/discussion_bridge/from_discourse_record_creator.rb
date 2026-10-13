# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class FromDiscourseRecordCreator
    Result = Data.define(:record, :outcome)

    def self.call(
      user:,
      connection_id:,
      topic_id:,
      external_id:,
      canonical_url:,
      lane: nil,
      native_materialization: false,
      presentation_mode: :unchanged
    )
      new(
        user: user,
        connection_id: connection_id,
        topic_id: topic_id,
        external_id: external_id,
        canonical_url: canonical_url,
        lane: lane,
        native_materialization: native_materialization,
        presentation_mode: presentation_mode,
      ).call
    end

    def initialize(
      user:,
      connection_id:,
      topic_id:,
      external_id:,
      canonical_url:,
      lane:,
      native_materialization:,
      presentation_mode:
    )
      @user = user
      @connection_id = connection_id
      @topic_id = topic_id
      @external_id = external_id
      @canonical_url = canonical_url
      @lane = lane
      @native_materialization = native_materialization
      @presentation_mode = presentation_mode
    end

    def call
      if [true, false].exclude?(@native_materialization)
        raise ArgumentError, "invalid native_materialization"
      end
      unless @presentation_mode == :unchanged || @presentation_mode.nil? ||
               DiscussionBridgeContentBinding::PRESENTATION_MODES.include?(@presentation_mode)
        raise ArgumentError, "invalid presentation_mode"
      end
      unless DiscussionBridgeContentBinding.valid_external_id?(@external_id)
        raise ArgumentError, "invalid external_id"
      end

      result = nil
      DiscussionBridgeBridgeRecord.transaction do
        connection = DiscussionBridgeContentConnection.lock.find(@connection_id)
        unless connection.enabled && connection.allows_direction?("from_discourse")
          raise ArgumentError, "connection does not permit From Discourse"
        end
        lane = resolved_lane(connection)

        topic = Topic.lock.find(@topic_id)
        raise Discourse::InvalidAccess unless Guardian.new(@user).can_see?(topic)
        raise Discourse::InvalidAccess unless SourceEdition.publicly_available?(topic)
        if topic.deleted_at || topic.first_post.nil? || topic.first_post.deleted_at
          raise ArgumentError, "topic is unavailable"
        end

        canonical =
          CanonicalSource.call(connection_id: connection.public_id, source_url: @canonical_url)
        unless connection.allows_origin?(canonical.source_url)
          raise ArgumentError, "origin is outside connection scope"
        end

        identity_digest = Digest::SHA256.hexdigest("#{connection.public_id}\n#{@external_id}")
        canonical_url_digest =
          Digest::SHA256.hexdigest("#{connection.public_id}\n#{canonical.source_url}")
        bindings =
          DiscussionBridgeContentBinding
            .lock
            .where(
              "identity_digest = :identity OR canonical_url_digest = :url",
              identity: identity_digest,
              url: canonical_url_digest,
            )
            .to_a

        if bindings.any?
          binding = bindings.one? ? bindings.first : nil
          valid =
            binding && binding.content_connection_id == connection.id &&
              binding.role == "presentation" && binding.state == "active" &&
              binding.external_id == @external_id &&
              binding.canonical_url == canonical.source_url &&
              binding.native_materialization == @native_materialization &&
              binding.bridge_record.direction == "from_discourse" &&
              binding.bridge_record.lane.to_s == lane.to_s &&
              binding.bridge_record.topic_id == topic.id
          raise ArgumentError, "binding identity conflict" unless valid
          unless @presentation_mode == :unchanged
            binding.update!(presentation_mode: @presentation_mode)
          end

          result = Result.new(record: binding.bridge_record, outcome: "resolved")
          next
        end

        record =
          DiscussionBridgeBridgeRecord.create!(
            resource_id: SecureRandom.uuid,
            direction: "from_discourse",
            lane: lane,
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
          presentation_mode: @presentation_mode == :unchanged ? nil : @presentation_mode,
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
      unless connection.allows_lane?(resolved)
        raise ArgumentError, "lane is outside connection scope"
      end

      resolved
    end
  end
end
