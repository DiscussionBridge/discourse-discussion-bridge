# frozen_string_literal: true

require "json"

module DiscussionBridge
  class LanePolicies
    ParseError = Class.new(StandardError)
    Resolution = Data.define(:configured, :allowed, :reason, :category_id, :tags)

    MAX_POLICIES = 100
    LANE_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/

    def self.parse(value)
      return [] if value.blank?

      parsed = JSON.parse(value)
      raise ParseError, "lane policies must be an array" unless parsed.is_a?(Array)
      raise ParseError, "too many lane policies" if parsed.length > MAX_POLICIES

      lanes = {}
      parsed.map do |entry|
        raise ParseError, "each lane policy must be an object" unless entry.is_a?(Hash)

        lane = entry["lane"].to_s
        raise ParseError, "invalid lane" unless LANE_PATTERN.match?(lane)
        raise ParseError, "duplicate lane" if lanes[lane]

        lanes[lane] = true
        category_id = Integer(entry["category_id"], exception: false)
        raise ParseError, "invalid category" unless category_id&.positive?

        tags = entry.fetch("tags", [])
        raise ParseError, "invalid tags" unless tags.is_a?(Array) && tags.all? { |tag| tag.is_a?(String) && tag.present? }

        visibility = entry.fetch("visibility", "unlisted")
        raise ParseError, "invalid visibility" unless visibility == "unlisted"

        {
          lane: lane,
          category_id: category_id,
          tags: tags.map(&:strip).reject(&:empty?).uniq,
          visibility: visibility,
        }
      end
    rescue JSON::ParserError
      raise ParseError, "invalid JSON"
    end

    def self.resolve(value:, lane:)
      policies = parse(value)
      return Resolution.new(configured: false, allowed: true, reason: "global_policy", category_id: nil, tags: nil) if policies.empty?
      return denied("lane_required") if lane.blank?

      policy = policies.find { |candidate| candidate[:lane] == lane.to_s }
      return denied("lane_denied") unless policy

      Resolution.new(
        configured: true,
        allowed: true,
        reason: "lane_policy_applied",
        category_id: policy[:category_id],
        tags: policy[:tags],
      )
    rescue ParseError
      denied("lane_policy_invalid")
    end

    def self.denied(reason)
      Resolution.new(configured: true, allowed: false, reason: reason, category_id: nil, tags: nil)
    end
    private_class_method :denied
  end
end
