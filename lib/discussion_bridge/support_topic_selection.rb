# frozen_string_literal: true

module DiscussionBridge
  module SupportTopicSelection
    FIELDS = %w[include_topic_ids exclude_topic_ids].freeze

    def self.source_in_scope?(topic, policy)
      return false if !topic.visible && !policy.fetch("include_unlisted")
      id = topic.id.to_s
      policy.fetch("selection") == "all_public" ||
        policy.fetch("category_ids").include?(topic.category_id.to_s) ||
        policy.fetch("include_topic_ids").include?(id) ||
        policy.fetch("exclude_topic_ids").include?(id)
    end

    def self.configuration(previous, topic_id, selected:)
      raise Discourse::InvalidAccess unless selected == true || selected == false
      value = previous.deep_dup
      policy = value.fetch("policy")
      policy.fetch("include_topic_ids").delete(topic_id)
      policy.fetch("exclude_topic_ids").delete(topic_id)
      policy.fetch(selected ? "include_topic_ids" : "exclude_topic_ids") << topic_id
      value
    end

    # The support role may change exactly one named topic selection. Every
    # connection setting, global policy field and every other topic stays exact.
    def self.validate_change!(before, after, topic_id)
      left, right = before.deep_dup, after.deep_dup
      FIELDS.each do |field|
        left.fetch("policy")[field] = left.fetch("policy").fetch(field).reject { |id| id == topic_id }
        right.fetch("policy")[field] = right.fetch("policy").fetch(field).reject { |id| id == topic_id }
      end
      left.fetch("policy").delete("policy_revision")
      right.fetch("policy").delete("policy_revision")
      raise Discourse::InvalidAccess unless left == right
      true
    end
  end
end
