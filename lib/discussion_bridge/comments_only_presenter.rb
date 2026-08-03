# frozen_string_literal: true

module DiscussionBridge
  class CommentsOnlyPresenter
    CSS_CLASS = "discussion-bridge-comments-only"
    CLASS_NAME_PATTERN = /\A[a-zA-Z0-9\-_ ]+\z/

    def self.class_name(topic_id:, embed_mode:)
      return unless SiteSetting.discussion_bridge_enabled
      return unless SiteSetting.discussion_bridge_comments_only_full_interactive
      return unless SiteSetting.embed_full_app
      return unless embed_mode

      id = Integer(topic_id, exception: false)
      return unless id&.positive?
      return unless DiscussionBridgeConnection.exists?(topic_id: id, state: "complete")

      CSS_CLASS
    end

    def self.redirect_class_name(topic_id:, full_app:, existing_class_name: nil)
      return existing_class_name unless full_app
      return unless existing_class_name.blank? || existing_class_name.match?(CLASS_NAME_PATTERN)

      classes = existing_class_name.to_s.split.reject { |name| name == CSS_CLASS }
      classes << CSS_CLASS if class_name(topic_id: topic_id, embed_mode: true)
      classes.join(" ").presence
    end
  end
end
