# frozen_string_literal: true

module DiscussionBridge
  class SourceTopicFeedSnapshot
    PURPOSE = "discussion-bridge-source-topic-feed"
    MAX_TOKEN_BYTES = 8_192
    FEEDS = %w[topics revocations].freeze
    Run = Data.define(:feed, :high_water_id, :total, :policy_revision, :after_id)

    def self.start(connection:, relation:, feed:)
      raise ArgumentError, "invalid source feed" if FEEDS.exclude?(feed)
      Run.new(
        feed: feed,
        high_water_id: relation.maximum(:id).to_i,
        total: relation.count,
        policy_revision: TopicPublicationState.policy_revision(connection),
        after_id: 0,
      )
    end

    def self.issue(connection:, run:)
      verifier.generate(
        {
          "connection_id" => connection.id,
          "feed" => run.feed,
          "high_water_id" => run.high_water_id,
          "total" => run.total,
          "policy_revision" => run.policy_revision,
          "after_id" => run.after_id,
        },
        purpose: PURPOSE,
      )
    end

    def self.load(token, connection:, feed:)
      raise ArgumentError, "invalid source feed cursor" if token.to_s.bytesize > MAX_TOKEN_BYTES
      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      valid_identity = payload.is_a?(Hash) && payload["connection_id"] == connection.id &&
        payload["feed"] == feed && FEEDS.include?(feed)
      raise ArgumentError, "invalid source feed cursor" unless valid_identity
      raise ArgumentError, "source feed cursor is stale" unless
        payload["policy_revision"] == TopicPublicationState.policy_revision(connection)

      Run.new(
        feed: feed,
        high_water_id: Integer(payload.fetch("high_water_id")),
        total: Integer(payload.fetch("total")),
        policy_revision: payload.fetch("policy_revision"),
        after_id: Integer(payload.fetch("after_id")),
      )
    rescue ActiveSupport::MessageVerifier::InvalidSignature, KeyError, TypeError
      raise ArgumentError, "invalid source feed cursor"
    end

    def self.advance(run, after_id:)
      Run.new(
        feed: run.feed,
        high_water_id: run.high_water_id,
        total: run.total,
        policy_revision: run.policy_revision,
        after_id: after_id,
      )
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_source_topic_feed)
    end

    private_class_method :verifier
  end
end
