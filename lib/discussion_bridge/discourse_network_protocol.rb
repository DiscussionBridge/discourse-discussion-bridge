# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  module DiscourseNetworkProtocol
    PROVENANCE_FIELDS = %w[
      origin_forum_id
      origin_forum_name
      origin_topic_url
      content_authority_forum_id
      relationship
      operation_id
      route_forum_ids
      managed_scope
    ].freeze
    IMMUTABLE_FIELDS = %w[
      source_revision
      content_sha256
      route_forum_ids
      relationship
      managed_scope
      policy_revision
    ].freeze
    RELATIONSHIPS = %w[hub_to_spoke spoke_to_hub].freeze
    MANAGED_SCOPES = %w[first_post].freeze
    FORUM_ID_PATTERN = /\Adbf_[a-f0-9]{32}\z/
    OPERATION_ID_PATTERN = /\Adbo_[a-f0-9]{32}\z/
    SHA256_PATTERN = /\A[a-f0-9]{64}\z/
    ROUTE_MAXIMUM_FORUMS = 8
    ORIGIN_FORUM_NAME_MAXIMUM_BYTES = 200
    REPLAY_RETENTION = 31_536_000
    CATALOG_REVISION = "catalog:discourse-network:alpha21"
    DEFAULT_NATIVE_LIMIT_BYTES = 49_152

    def self.forum_id
      "dbf_#{SecureRandom.hex(16)}"
    end

    def self.operation_id
      "dbo_#{SecureRandom.hex(16)}"
    end

    def self.destination_policy(peer_forum_id:, relationship:)
      validate_id!(peer_forum_id, FORUM_ID_PATTERN)
      raise AdapterRequestBoundary::Error, "validation_failed" if RELATIONSHIPS.exclude?(relationship)

      {
        "destination_policy_id" => "destination:discourse-network:#{peer_forum_id}",
        "profile" => "discourse_as_publisher",
        "presentation_mode" => "interactive",
        "container_mapping" => {
          "source" => "discourse:network:source",
          "destination" => "discourse:network:default",
        },
        "taxonomy_mapping" => { "mode" => "source_attribution" },
        "author_mapping" => { "mode" => "source_attribution" },
        "native_limit_policy" => {
          "maximum_bytes" => DEFAULT_NATIVE_LIMIT_BYTES,
          "overflow_behavior" => "excerpt_with_read_more",
        },
        "catalog_revision" => CATALOG_REVISION,
      }
    end

    def self.policy_revision(peer_forum_id:, relationship:)
      policy = destination_policy(peer_forum_id: peer_forum_id, relationship: relationship)
      "policy:discourse-network:#{digest(policy.merge("relationship" => relationship))[0, 32]}"
    end

    def self.validate_provenance!(value, peer:, local_identity:)
      raw = exact_object!(value, PROVENANCE_FIELDS)
      validate_id!(raw["origin_forum_id"], FORUM_ID_PATTERN)
      validate_label!(raw["origin_forum_name"], ORIGIN_FORUM_NAME_MAXIMUM_BYTES)
      raw["origin_topic_url"] = canonical_https_url!(raw["origin_topic_url"])
      validate_id!(raw["content_authority_forum_id"], FORUM_ID_PATTERN)
      if RELATIONSHIPS.exclude?(raw["relationship"]) ||
          MANAGED_SCOPES.exclude?(raw["managed_scope"])
        raise AdapterRequestBoundary::Error, "validation_failed"
      end
      validate_id!(raw["operation_id"], OPERATION_ID_PATTERN)
      route = raw["route_forum_ids"]
      unless route.is_a?(Array) && route.length.between?(1, ROUTE_MAXIMUM_FORUMS) &&
          route.uniq == route && route.all? { |forum_id| FORUM_ID_PATTERN.match?(forum_id.to_s) }
        raise AdapterRequestBoundary::Error, "validation_failed"
      end
      origin = url_origin(raw["origin_topic_url"])
      if raw["origin_forum_id"] != peer.remote_forum_id ||
          raw["origin_forum_name"] != peer.remote_forum_name ||
          raw["content_authority_forum_id"] != raw["origin_forum_id"] ||
          raw["relationship"] != peer.relationship ||
          route.first != raw["origin_forum_id"] ||
          route.last != peer.remote_forum_id ||
          origin != peer.remote_origin
        raise AdapterRequestBoundary::Error, "scope_denied"
      end
      if local_identity.reserved_forum_id?(raw["origin_forum_id"]) ||
          route.any? { |forum_id| local_identity.reserved_forum_id?(forum_id) }
        raise AdapterRequestBoundary::Error, "scope_denied"
      end
      raw
    end

    def self.append_local_route!(provenance, local_identity:)
      route = Array(provenance.fetch("route_forum_ids"))
      raise AdapterRequestBoundary::Error, "validation_failed" if route.length >= ROUTE_MAXIMUM_FORUMS

      provenance.merge("route_forum_ids" => route + [local_identity.forum_id])
    end

    def self.immutable_operation(source_detail:, provenance:, policy_revision:)
      operation = {
        "source_revision" => source_detail.fetch("source_revision"),
        "content_sha256" => source_detail.dig("content_transport", "sha256"),
        "route_forum_ids" => provenance.fetch("route_forum_ids"),
        "relationship" => provenance.fetch("relationship"),
        "managed_scope" => provenance.fetch("managed_scope"),
        "policy_revision" => policy_revision,
      }
      exact_object!(operation, IMMUTABLE_FIELDS)
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.canonical(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value.fetch(key)) }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end
    private_class_method :canonical

    def self.exact_object!(value, fields)
      unless value.is_a?(Hash) && value.keys.map(&:to_s).sort == fields.sort
        raise AdapterRequestBoundary::Error, "validation_failed"
      end

      value.deep_stringify_keys
    end
    private_class_method :exact_object!

    def self.validate_id!(value, pattern)
      raise AdapterRequestBoundary::Error, "validation_failed" unless pattern.match?(value.to_s)
    end
    private_class_method :validate_id!

    def self.validate_label!(value, maximum)
      valid = value.is_a?(String) && value.valid_encoding? && value.present? &&
        value == value.strip && value.bytesize <= maximum && !/[\x00-\x1f\x7f]/.match?(value)
      raise AdapterRequestBoundary::Error, "validation_failed" unless valid
    end
    private_class_method :validate_label!

    def self.canonical_https_url!(value)
      canonical = CanonicalSource.call(connection_id: "network-origin", source_url: value.to_s).source_url
      raise AdapterRequestBoundary::Error, "validation_failed" unless URI.parse(canonical).scheme == "https"

      canonical
    rescue ArgumentError, URI::InvalidURIError
      raise AdapterRequestBoundary::Error, "validation_failed"
    end
    private_class_method :canonical_https_url!

    def self.url_origin(value)
      uri = URI.parse(value)
      origin = "#{uri.scheme}://#{uri.host}"
      origin += ":#{uri.port}" unless uri.port == uri.default_port
      CanonicalSource.origin(origin)
    rescue ArgumentError, URI::InvalidURIError
      raise AdapterRequestBoundary::Error, "validation_failed"
    end
    private_class_method :url_origin
  end
end
