# frozen_string_literal: true

module DiscussionBridge
  module ExistingMappingIntegrity
    ESTATE_REASON_TO_RECONCILIATION_CODE = {
      "mapping_topic_missing" => "topic_missing",
      "mapping_topic_deleted" => "topic_deleted",
      "mapping_topic_archetype_mismatch" => "topic_archetype_mismatch",
      "mapping_topic_closed" => "topic_closed",
      "mapping_topic_archived" => "topic_archived",
      "mapping_actor_drift" => "actor_drift",
      "mapping_actor_invalid" => "actor_drift",
      "mapping_effective_visibility_drift" => "effective_visibility_drift",
      "mapping_topic_visibility_drift" => "visibility_drift",
      "mapping_category_drift" => "category_drift",
      "mapping_tag_drift" => "tag_drift",
      "mapping_first_post_missing" => "first_post_missing",
      "mapping_first_post_deleted" => "first_post_deleted",
    }.freeze
    REQUEST_RELATIVE_REASONS = %w[mapping_lane_drift].freeze
    Result = Data.define(:usable?, :reason, :topic, :mapping)

    CurrentPolicy = Data.define(
      :effective_actor_id,
      :effective_visibility,
      :effective_category_id,
      :effective_tags,
    )

    def self.current(mapping_id:, expected_topic_id: nil, expected_updated_at: nil)
      result = nil
      DiscussionBridgeConnection.transaction(requires_new: true) do
        mapping = DiscussionBridgeConnection.lock.find_by(id: mapping_id, state: "complete")
        if !mapping
          result = denied("mapping_incomplete")
          next
        end
        if expected_topic_id && mapping.topic_id != expected_topic_id
          result = denied("mapping_topic_changed")
          next
        end
        if expected_updated_at && mapping.updated_at.utc.iso8601(6) != expected_updated_at.utc.iso8601(6)
          result = denied("mapping_version_changed")
          next
        end

        policy = current_policy(mapping)
        result = policy.is_a?(Result) ? policy : call(
          mapping: mapping,
          policy: policy,
          request: { lane: mapping.lane },
        )
      end
      result
    end

    def self.call(mapping:, policy:, request:)
      return denied("mapping_topic_missing") unless mapping.topic_id

      topic = Topic.lock.find_by(id: mapping.topic_id)
      return denied("mapping_topic_missing") unless topic
      return denied("mapping_topic_deleted") if topic.deleted_at.present?
      return denied("mapping_topic_archetype_mismatch") unless topic.archetype == Archetype.default
      return denied("mapping_topic_closed") if topic.closed?
      return denied("mapping_topic_archived") if topic.archived?
      return denied("mapping_lane_drift") unless mapping.lane.to_s == request[:lane].to_s
      return denied("mapping_actor_drift") unless mapping.effective_actor_id == policy.effective_actor_id &&
        topic.user_id == policy.effective_actor_id
      unless mapping.effective_visibility == policy.effective_visibility
        return denied("mapping_effective_visibility_drift")
      end
      return denied("mapping_category_drift") unless topic.category_id == policy.effective_category_id
      return denied("mapping_topic_visibility_drift") if topic.visible

      expected_tags = Array(policy.effective_tags).map(&:to_s).sort
      locked_tag_ids = TopicTag.lock.where(topic_id: topic.id).pluck(:tag_id)
      actual_tags = Tag.lock.where(id: locked_tag_ids).pluck(:name).sort
      return denied("mapping_tag_drift") unless actual_tags == expected_tags

      first_post = Post.lock.find_by(topic_id: topic.id, post_number: 1)
      return denied("mapping_first_post_missing") unless first_post
      return denied("mapping_first_post_deleted") if first_post.deleted_at.present?

      actor = User.find_by(id: policy.effective_actor_id)
      return denied("mapping_actor_invalid") unless actor && actor.guardian.can_see?(topic)

      Result.new(usable?: true, reason: nil, topic: topic, mapping: mapping)
    end

    def self.current_policy(mapping)
      actor = User.find_by(
        username_lower: SiteSetting.discussion_bridge_service_username.to_s.downcase,
      )
      return denied("mapping_actor_invalid") unless actor && actor.active? && !actor.staged? &&
        !actor.suspended? && !actor.silenced? && actor.id != Discourse::SYSTEM_USER_ID

      lane = LanePolicies.resolve(
        value: SiteSetting.discussion_bridge_lane_policies,
        lane: mapping.lane,
      )
      return denied(lane.reason) unless lane.allowed

      authority = ForumAuthority.call(
        actor: actor,
        category_id: lane.category_id || SiteSetting.discussion_bridge_effective_category_id,
        tags: lane.tags || SiteSetting.discussion_bridge_effective_tags,
      )
      return denied(authority.reason) unless authority.allowed?

      CurrentPolicy.new(
        effective_actor_id: actor.id,
        effective_visibility: "unlisted",
        effective_category_id: authority.category_id,
        effective_tags: authority.tags,
      )
    rescue LanePolicies::ParseError
      denied("lane_policy_invalid")
    end
    private_class_method :current_policy

    def self.denied(reason)
      Result.new(usable?: false, reason: reason, topic: nil, mapping: nil)
    end
    private_class_method :denied
  end
end
