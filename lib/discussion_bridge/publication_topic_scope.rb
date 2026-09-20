# frozen_string_literal: true

module DiscussionBridge
  class PublicationTopicScope
    def self.relation(connection)
      topics = Topic.joins(:first_post).left_joins(:category)
        .where(archetype: Archetype.default, deleted_at: nil)
        .where(posts: { deleted_at: nil })
        .where("topics.category_id IS NULL OR categories.read_restricted = FALSE")
      topics = topics.where(visible: true) unless connection.publication_include_unlisted

      included = Array(connection.publication_category_ids).map(&:to_i)
      excluded = Array(connection.publication_excluded_category_ids).map(&:to_i)
      if connection.publication_category_mode == "only_selected"
        topics = topics.where(category_id: included)
      else
        topics = topics.where.not(category_id: excluded) if excluded.any?
      end

      included_tags = Array(connection.publication_tag_ids).map(&:to_i)
      excluded_tags = Array(connection.publication_excluded_tag_ids).map(&:to_i)
      if connection.publication_tag_mode == "only_selected"
        topics = topics.where(id: TopicTag.where(tag_id: included_tags).select(:topic_id))
      elsif connection.publication_tag_mode == "all_except_selected" && excluded_tags.any?
        topics = topics.where.not(id: TopicTag.where(tag_id: excluded_tags).select(:topic_id))
      end
      topics
    end

    def self.find!(connection, topic_id)
      relation(connection).find(topic_id)
    end

    def self.eligibility(connection, topic)
      return { eligible: false, reason: "topic_deleted" } if topic.deleted_at || topic.first_post.nil?
      return { eligible: false, reason: "topic_not_regular" } unless topic.archetype == Archetype.default
      return { eligible: false, reason: "category_private" } if topic.category&.read_restricted
      if !connection.publication_include_unlisted && !topic.visible
        return { eligible: false, reason: "topic_unlisted" }
      end

      included_categories = Array(connection.publication_category_ids).map(&:to_i)
      excluded_categories = Array(connection.publication_excluded_category_ids).map(&:to_i)
      if connection.publication_category_mode == "only_selected" &&
          !included_categories.include?(topic.category_id)
        return { eligible: false, reason: "category_not_selected" }
      end
      if connection.publication_category_mode == "all_except_selected" &&
          excluded_categories.include?(topic.category_id)
        return { eligible: false, reason: "category_excluded" }
      end

      topic_tag_ids = topic.tags.map(&:id)
      included_tags = Array(connection.publication_tag_ids).map(&:to_i)
      excluded_tags = Array(connection.publication_excluded_tag_ids).map(&:to_i)
      if connection.publication_tag_mode == "only_selected" && (topic_tag_ids & included_tags).empty?
        return { eligible: false, reason: "tag_not_selected" }
      end
      if connection.publication_tag_mode == "all_except_selected" &&
          (topic_tag_ids & excluded_tags).any?
        return { eligible: false, reason: "tag_excluded" }
      end

      { eligible: true, reason: nil }
    end

    def self.revision(topic, post: topic.first_post)
      raise ArgumentError, "topic has no source post" unless post

      "post:#{post.id}:version:#{post.version}"
    end
  end
end
