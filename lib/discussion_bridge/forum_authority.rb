# frozen_string_literal: true

module DiscussionBridge
  class ForumAuthority
    Result = Data.define(:allowed?, :reason, :category_id, :tags)

    def self.call(actor:, category_id:, tags:)
      category = Category.find_by(id: category_id.to_i)
      return denied("category_unavailable") unless category

      guardian = actor.guardian
      return denied("category_denied") unless guardian.can_create_topic_on_category?(category)

      tag_names = list_values(tags)
      tag_records = Tag.where(name: tag_names).to_a
      return denied("tag_unavailable") unless tag_records.length == tag_names.length
      return denied("tag_denied") if tag_names.any? && !guardian.can_tag_topics?

      topic = Topic.new(category: category)
      return denied("unlisted_denied") unless guardian.can_create_unlisted_topic?(topic)
      return denied("tag_denied") unless DiscourseTagging.validate_category_tags(guardian, topic, category, tag_records)

      Result.new(allowed?: true, reason: "authorized", category_id: category.id, tags: tag_names)
    end

    def self.list_values(value)
      values = value.is_a?(String) ? value.split("|") : Array(value)
      values.map { |entry| entry.to_s.strip }.reject(&:empty?).uniq
    end
    private_class_method :list_values

    def self.denied(reason)
      Result.new(allowed?: false, reason: reason, category_id: nil, tags: [])
    end
    private_class_method :denied
  end
end
