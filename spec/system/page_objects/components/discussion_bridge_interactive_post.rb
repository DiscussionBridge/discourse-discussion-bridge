# frozen_string_literal: true

module PageObjects
  module Components
    class DiscussionBridgeInteractivePost < PageObjects::Components::Base
      def initialize(post, reactions_enabled:)
        @post_number = post.post_number
        @reactions_enabled = reactions_enabled
      end

      def like
        find("#{post_selector} #{like_control}[title=\"#{like_label}\"]").click
        self
      end

      def has_liked?
        has_css?("#{post_selector} #{like_control}[title=\"#{liked_label}\"]")
      end

      def reply
        find("#{post_selector} button.reply").click
        self
      end

      private

      def post_selector
        "#post_#{@post_number}"
      end

      def like_control
        @reactions_enabled ? ".discourse-reactions-reaction-button" : "button"
      end

      def like_label
        key =
          (
            if @reactions_enabled
              "discourse_reactions.main_reaction.add"
            else
              "post.controls.like"
            end
          )
        I18n.t("js.#{key}")
      end

      def liked_label
        key =
          (
            if @reactions_enabled
              "discourse_reactions.main_reaction.remove"
            else
              "post.controls.undo_like"
            end
          )
        I18n.t("js.#{key}")
      end
    end
  end
end
