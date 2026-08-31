# frozen_string_literal: true

module DiscussionBridge
  class CommentsOnlyPresenter
    CSS_CLASS = "discussion-bridge-comments-only"
    SOURCE_PRESENTATION_CLASS = "discussion-bridge-source-presentation"
    MAX_CLASS_NAME_BYTES = 256
    CLASS_NAME_PATTERN = /\A[a-zA-Z0-9\-_ ]+\z/

    def self.valid_existing_class_name?(value)
      return true if value.nil?
      return false unless value.is_a?(String)
      return false if value.bytesize > MAX_CLASS_NAME_BYTES
      return true if value.match?(/\A *\z/)

      value.match?(CLASS_NAME_PATTERN)
    end

    def self.valid_final_class_name?(value)
      return false unless value.is_a?(String) && value.bytesize <= MAX_CLASS_NAME_BYTES
      return false unless value.match?(CLASS_NAME_PATTERN)

      value.split.count(CSS_CLASS) == 1
    end

    def self.mapped_topic?(topic_id:)
      id = Integer(topic_id, exception: false)
      id&.positive? && (
        DiscussionBridgeBridgeRecord.exists?(
          topic_id: id,
          state: "healthy",
          direction: "to_discourse",
        ) ||
          DiscussionBridgeConnection.exists?(topic_id: id, state: "complete")
      )
    end

    def self.source_presentation_topic?(topic_id:)
      id = Integer(topic_id, exception: false)
      id&.positive? && DiscussionBridgeBridgeRecord.exists?(
        topic_id: id,
        state: "healthy",
        direction: "from_discourse",
      )
    end

    def self.source_presentation_requested?(class_name)
      valid_existing_class_name?(class_name) &&
        class_name.to_s.split.include?(SOURCE_PRESENTATION_CLASS)
    end

    def self.requested_for?(topic_id:, source_presentation: false)
      FullInteractiveReadiness.ready? && (
        mapped_topic?(topic_id: topic_id) ||
          (source_presentation && source_presentation_topic?(topic_id: topic_id))
      )
    end

    def self.class_name(topic_id:, embed_mode:, source_presentation: false)
      return unless SiteSetting.embed_full_app
      return unless embed_mode
      return unless requested_for?(topic_id: topic_id, source_presentation: source_presentation)

      CSS_CLASS
    end

    def self.redirect_class_name(topic_id:, full_app:, existing_class_name: nil)
      return existing_class_name unless full_app
      return unless valid_existing_class_name?(existing_class_name)

      classes = existing_class_name.to_s.split.reject { |name| name == CSS_CLASS }
      source_presentation = classes.delete(SOURCE_PRESENTATION_CLASS).present?
      classes << CSS_CLASS if class_name(
        topic_id: topic_id,
        embed_mode: true,
        source_presentation: source_presentation,
      )
      result = classes.join(" ").presence
      if classes.include?(CSS_CLASS)
        result if valid_final_class_name?(result)
      else
        result if valid_existing_class_name?(result)
      end
    end
  end
end
