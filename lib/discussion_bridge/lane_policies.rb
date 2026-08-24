# frozen_string_literal: true

require "json"

module DiscussionBridge
  class LanePolicies
    ParseError = Class.new(StandardError)
    class StrictHash < Hash
      def []=(key, value)
        raise ParseError, "duplicate lane policy field" if key?(key)

        super
      end
    end
    Resolution = Data.define(:configured, :allowed, :reason, :category_id, :tags)

    MAX_POLICIES = 100
    MAX_JSON_BYTES = 64 * 1024
    MAX_TAGS = 20
    MAX_TAG_BYTES = 100
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    REQUIRED_KEYS = %w[lane category_id tags visibility].freeze
    LANE_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    def self.parse(value)
      return [] if value.blank?
      raise ParseError, "lane policies are too large" if value.to_s.bytesize > MAX_JSON_BYTES

      parsed = JSON.parse(value, object_class: StrictHash)
      raise ParseError, "lane policies must be an array" unless parsed.is_a?(Array)
      raise ParseError, "too many lane policies" if parsed.length > MAX_POLICIES

      lanes = {}
      parsed.map do |entry|
        raise ParseError, "each lane policy must be an object" unless entry.is_a?(Hash)
        raise ParseError, "invalid lane policy schema" unless entry.keys.sort == REQUIRED_KEYS.sort

        lane = entry["lane"]
        raise ParseError, "invalid lane" unless lane.is_a?(String) && lane.valid_encoding? &&
          !CONTROL_PATTERN.match?(lane) && LANE_PATTERN.match?(lane)
        raise ParseError, "duplicate lane" if lanes[lane]

        lanes[lane] = true
        category_id = entry["category_id"]
        if category_id.is_a?(String) && /\A[1-9]\d*\z/.match?(category_id)
          category_id = Integer(category_id, exception: false)
        end
        unless category_id.is_a?(Integer) && category_id.positive? && category_id <= MAX_SAFE_INTEGER
          raise ParseError, "invalid category"
        end

        tags = entry["tags"]
        valid_tags = tags.is_a?(Array) && tags.length <= MAX_TAGS &&
          tags.all? { |tag|
            tag.is_a?(String) && tag.valid_encoding? && tag == tag.strip && tag.present? &&
              tag.bytesize <= MAX_TAG_BYTES && !CONTROL_PATTERN.match?(tag)
          }
        raise ParseError, "invalid tags" unless valid_tags
        raise ParseError, "duplicate tags" unless tags.map(&:downcase).uniq.length == tags.length

        visibility = entry["visibility"]
        raise ParseError, "invalid visibility" unless visibility == "unlisted"

        {
          lane: lane,
          category_id: category_id,
          tags: tags,
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
