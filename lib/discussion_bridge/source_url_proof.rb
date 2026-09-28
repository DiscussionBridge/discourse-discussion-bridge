# frozen_string_literal: true

module DiscussionBridge
  class SourceUrlProof
    MAXIMUM_TRANSITIONS = 20

    def self.call(connection:, record:, from_url:, to_url:)
      new(
        connection: connection,
        record: record,
        from_url: from_url,
        to_url: to_url,
      ).call
    end

    def initialize(connection:, record:, from_url:, to_url:)
      @connection = connection
      @record = record
      @from_url = from_url
      @to_url = to_url
    end

    def call
      DiscussionBridgeBridgeRecord.transaction do
        @connection.lock!
        @record.lock!
        binding = active_source_binding!
        from = canonical(@from_url)
        to = canonical(@to_url)
        fail_closed! if from == to || binding.canonical_url != to

        chain = current_chain(binding, from, to)
        verified_at = chain.last.verified_at
        {
          resource_id: @record.resource_id,
          topic_id: @record.topic_id,
          external_id: binding.external_id,
          from_url: from,
          to_url: to,
          verified: true,
          transition_count: chain.length,
          verified_at: verified_at.iso8601(6),
          transitions: chain.map do |transition|
            {
              old_url: transition.old_canonical_url,
              new_url: transition.new_canonical_url,
              redirect_status: transition.redirect_status,
              verified_at: transition.verified_at.iso8601(6),
            }
          end,
        }
      end
    end

    private

    def active_source_binding!
      valid = @record.direction == "to_discourse" && @record.state == "healthy" &&
        @connection.enabled && @connection.allows_direction?("to_discourse") &&
        @connection.allows_lane?(@record.lane)
      fail_closed! unless valid

      bindings = @record.content_bindings.where(
        content_connection_id: @connection.id,
        role: "source",
        state: "active",
      ).lock.to_a
      fail_closed! unless bindings.one?

      bindings.first
    end

    def canonical(value)
      result = CanonicalSource.call(connection_id: @connection.public_id, source_url: value)
      raise AdapterRequestBoundary::Error, "scope_denied" unless
        @connection.allows_origin?(result.source_url)

      result.source_url
    end

    def current_chain(binding, from, to)
      history = DiscussionBridgeSourceUrlHistory.where(content_binding_id: binding.id)
        .order(:id).to_a
      candidates = history.each_index.select { |index| history[index].old_canonical_url == from }
      chains = candidates.filter_map do |index|
        chain = history.drop(index)
        next if chain.empty? || chain.length > MAXIMUM_TRANSITIONS
        next unless valid_chain?(chain, from, to)

        chain
      end
      fail_closed! unless chains.one?

      chains.first
    end

    def valid_chain?(chain, from, to)
      cursor = from
      seen = Set.new([from])
      chain.each do |transition|
        return false unless transition.old_canonical_url == cursor &&
          [301, 308].include?(transition.redirect_status) && transition.verified_at.present?
        cursor = transition.new_canonical_url
        return false unless seen.add?(cursor)
      end
      cursor == to
    end

    def fail_closed!
      raise AdapterRequestBoundary::Error, "reconciliation_required"
    end
  end
end
