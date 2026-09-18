# frozen_string_literal: true

require "digest"

module DiscussionBridge
  class SourceUrlProof
    MAX_STEPS = 20

    def self.call(connection:, record:, from_url:, to_url:)
      new(connection: connection, record: record, from_url: from_url, to_url: to_url).call
    end

    def initialize(connection:, record:, from_url:, to_url:)
      @connection = connection
      @record = record
      @from_url = from_url
      @to_url = to_url
    end

    def call
      DiscussionBridgeBridgeRecord.transaction do
        @connection = DiscussionBridgeContentConnection.lock.find(@connection.id)
        @record = DiscussionBridgeBridgeRecord.lock.find(@record.id)
        prove_locked
      end
    end

    private

    def prove_locked
      raise ArgumentError, "source record is unavailable" unless
        @record.direction == "to_discourse" && @record.state == "healthy" &&
          @connection.enabled && @connection.allows_direction?("to_discourse") &&
          @connection.allows_lane?(@record.lane)

      bindings = @record.content_bindings.where(
        content_connection_id: @connection.id, role: "source", state: "active"
      ).lock.to_a
      raise ArgumentError, "source binding is ambiguous" unless bindings.one?
      binding = bindings.first
      from = canonical(@from_url)
      to = canonical(@to_url)
      raise ArgumentError, "source URL proof requires a changed URL" if from == to
      raise ArgumentError, "source destination is not current" unless binding.canonical_url == to

      from_digest = Digest::SHA256.hexdigest("#{@connection.public_id}\n#{from}")
      history = DiscussionBridgeSourceUrlHistory.where(content_binding_id: binding.id)
      raise ArgumentError, "source URL ancestry is ambiguous" unless
        history.where(old_canonical_url_digest: from_digest).count == 1

      recent = history.order(id: :desc).limit(MAX_STEPS + 1).to_a.reverse
      start = recent.index { |step| step.old_canonical_url == from }
      raise ArgumentError, "source URL ancestry is missing or exceeds the limit" unless start
      chain = recent.drop(start)
      raise ArgumentError, "source URL ancestry exceeds the limit" if chain.length > MAX_STEPS

      cursor = from
      seen = Set.new([from])
      chain.each do |step|
        raise ArgumentError, "source URL ancestry is discontinuous" unless
          step.old_canonical_url == cursor && [301, 308].include?(step.redirect_status) &&
            step.verified_at.present?
        cursor = step.new_canonical_url
        raise ArgumentError, "source URL ancestry contains a cycle" unless seen.add?(cursor)
      end
      raise ArgumentError, "source URL ancestry does not reach the active URL" unless cursor == to

      {
        resource_id: @record.resource_id,
        topic_id: @record.topic_id,
        external_id: binding.external_id,
        from_url: from,
        to_url: to,
        verified: true,
        transition_count: chain.length,
        verified_at: chain.last.verified_at.iso8601(6),
      }
    end

    def canonical(value)
      url = CanonicalSource.call(connection_id: @connection.public_id, source_url: value).source_url
      raise ArgumentError, "source URL is outside connection scope" unless @connection.allows_origin?(url)

      url
    end
  end
end
