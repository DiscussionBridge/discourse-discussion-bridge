# frozen_string_literal: true

module DiscussionBridge
  # Native source eligibility and SQL snapshot columns shared by the V4 feed.
  class SourceEdition
    class Unavailable < StandardError; end
    class InvalidForumName < StandardError; end
    SOURCE_COLUMNS = %w[
      topics.id
      topics.title
      topics.slug
      topics.created_at
      posts.id
      posts.post_number
      posts.version
      posts.created_at
      posts.updated_at
      posts.raw
      posts.cooked
      users.username
      users.username_lower
      users.name
    ].freeze

    def self.publicly_available?(topic)
      anonymous = Guardian.new(nil)
      !SiteSetting.login_required && topic && !topic.private_message? && topic.deleted_at.nil? &&
        anonymous.can_see?(topic) && !SharedDraft.exists?(topic_id: topic.id) &&
        !DiscussionBridgeBridgeRecord.exists?(direction: "to_discourse", topic_id: topic.id) &&
        topic.first_post && topic.first_post.deleted_at.nil? &&
        anonymous.can_see?(topic.first_post) &&
        !TopicEmbed.with_deleted.exists?(post_id: topic.first_post.id)
    end
  end
end
