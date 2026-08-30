# frozen_string_literal: true

require "securerandom"

module ::Jobs
  class DiscussionBridgePublisherDeliver < ::Jobs::Base
    sidekiq_options retry: 5

    def execute(args)
      raise Discourse::InvalidParameters.new(:topic_id) unless args[:topic_id]

      topic = Topic.find(args[:topic_id])
      correlation_id = SecureRandom.uuid
      attempts = topic.custom_fields[DiscussionBridge::Publisher::ATTEMPTS_FIELD].to_i + 1
      topic.custom_fields[DiscussionBridge::Publisher::ATTEMPTS_FIELD] = attempts.to_s
      topic.custom_fields[DiscussionBridge::Publisher::CORRELATION_ID_FIELD] = correlation_id
      topic.custom_fields[DiscussionBridge::Publisher::PUBLISH_STATE_FIELD] = "delivering"
      topic.save_custom_fields

      record = DiscussionBridge::Publisher::Client.new.resolve(topic: topic, correlation_id: correlation_id)
      validate_record!(record)

      topic.custom_fields[DiscussionBridge::Publisher::RESOURCE_ID_FIELD] = record.fetch("resource_id")
      topic.custom_fields[DiscussionBridge::Publisher::REMOTE_TOPIC_ID_FIELD] = record.fetch("topic_id").to_s
      topic.custom_fields[DiscussionBridge::Publisher::REMOTE_TOPIC_URL_FIELD] = record.fetch("topic_url")
      topic.custom_fields[DiscussionBridge::Publisher::PUBLISH_STATE_FIELD] = record.fetch("outcome")
      topic.save_custom_fields
    rescue DiscussionBridge::Publisher::Client::Error, KeyError, TypeError, ArgumentError => error
      if topic
        topic.custom_fields[DiscussionBridge::Publisher::PUBLISH_STATE_FIELD] = "failed:#{error.message.to_s.first(80)}"
        topic.save_custom_fields
      end
      raise
    end

    private

    def validate_record!(record)
      raise TypeError, "invalid_record" unless record.is_a?(Hash)
      raise ArgumentError, "invalid_direction" unless record["direction"] == "to_discourse"
      raise ArgumentError, "invalid_core_fallback" unless record["core_fallback"] == false
      raise ArgumentError, "invalid_resource_id" unless DiscussionBridge::Publisher::Client::RESOURCE_ID_PATTERN.match?(record["resource_id"].to_s)
      raise ArgumentError, "invalid_topic_id" unless record["topic_id"].is_a?(Integer) && record["topic_id"].positive?
      receiver = URI.parse(SiteSetting.discussion_bridge_publisher_receiver_url)
      topic_url = URI.parse(record["topic_url"].to_s)
      raise ArgumentError, "invalid_topic_url" unless topic_url.is_a?(URI::HTTPS) && topic_url.origin == receiver.origin && topic_url.query.nil? && topic_url.fragment.nil?
      raise ArgumentError, "invalid_outcome" unless %w[created resolved].include?(record["outcome"])
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid_topic_url"
    end
  end
end
