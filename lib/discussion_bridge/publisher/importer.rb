# frozen_string_literal: true

module ::DiscussionBridge
  module Publisher
    class Importer
      class Error < StandardError; end

      def initialize(user:, resource_id:)
        @user = user
        @resource_id = resource_id.to_s
        raise Error, "invalid_resource_id" unless Client::RESOURCE_ID_PATTERN.match?(@resource_id)
      end

      def call
        DistributedMutex.synchronize("discussion_bridge_publisher_import_#{@resource_id}") do
          existing = TopicCustomField.find_by(name: SOURCE_RESOURCE_ID_FIELD, value: @resource_id)&.topic
          return existing if existing

          payload = Client.new.fetch(@resource_id).fetch("bridge_record")
          validate!(payload)
          created_post = PostCreator.new(
            @user,
            title: payload.fetch("title").to_s.first(255),
            raw: import_raw(payload),
            category: import_category,
            skip_validations: false,
          ).create
          raise Error, created_post.errors.full_messages.join(", ") if created_post.errors.any?

          topic = created_post.topic
          topic.custom_fields[SOURCE_RESOURCE_ID_FIELD] = @resource_id
          topic.custom_fields[PUBLISH_STATE_FIELD] = "imported"
          topic.custom_fields[REMOTE_TOPIC_ID_FIELD] = payload.fetch("topic_id").to_s
          topic.custom_fields[REMOTE_TOPIC_URL_FIELD] = payload.fetch("topic_url")
          topic.save_custom_fields
          topic
        end
      rescue Client::Error, KeyError, TypeError, ArgumentError => error
        raise Error, error.message
      end

      private

      def validate!(record)
        raise TypeError, "invalid_record" unless record.is_a?(Hash)
        raise Error, "invalid_resource" unless record["resource_id"] == @resource_id
        raise Error, "invalid_direction" unless record["direction"] == "from_discourse"
        raise Error, "invalid_state" unless record["state"] == "healthy"
        raise Error, "invalid_topic_id" unless record["topic_id"].is_a?(Integer) && record["topic_id"].positive?
        url = URI.parse(record.fetch("topic_url"))
        receiver = URI.parse(SiteSetting.discussion_bridge_publisher_receiver_url)
        raise Error, "invalid_topic_url" unless url.is_a?(URI::HTTPS) && url.origin == receiver.origin && url.query.nil? && url.fragment.nil?
        raise Error, "invalid_content" unless record["content_html"].is_a?(String) && record["content_html"].bytesize <= Client::MAX_RESPONSE_BYTES
      rescue URI::InvalidURIError
        raise Error, "invalid_topic_url"
      end

      def import_category
        category_id = SiteSetting.discussion_bridge_publisher_import_category_id.to_i
        category_id.positive? ? category_id : SiteSetting.uncategorized_category_id
      end

      def import_raw(record)
        text = ActionView::Base.full_sanitizer.sanitize(record.fetch("content_html")).to_s.strip.first(20_000)
        escaped = text.gsub(/([\\`*_{}\[\]()#+\-.!>|])/, '\\\\\1')
        "Imported through DiscussionBridge from [the source discussion](#{record.fetch("topic_url")}).\n\n#{escaped}"
      end
    end
  end
end
