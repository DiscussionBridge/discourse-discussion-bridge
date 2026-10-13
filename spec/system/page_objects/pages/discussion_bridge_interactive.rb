# frozen_string_literal: true

module PageObjects
  module Pages
    class DiscussionBridgeInteractive < PageObjects::Pages::Base
      def visit_topic(topic)
        page.visit("/embed/comments?topic_id=#{topic.id}&full_app=true")
        self
      end

      def post_menu(post, reactions_enabled:)
        PageObjects::Components::DiscussionBridgeInteractivePost.new(
          post,
          reactions_enabled: reactions_enabled
        )
      end

      def has_reply_composer?
        has_css?(".embed-mode-composer .d-editor-input")
      end

      def reply_with(text)
        find(".embed-mode-composer .d-editor-input").set(text)
        find(".embed-mode-composer .docked-composer__submit-btn").click
        self
      end

      def has_reply?(text)
        has_css?(".topic-post", text: text)
      end

      def in_embed_mode?
        has_current_path?(/embed_mode=true/, url: true) &&
          has_css?("body.embed-mode")
      end
    end
  end
end
