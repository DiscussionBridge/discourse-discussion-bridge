# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "openssl"
require "time"

module DiscussionBridge
  class OperatorEntitlementVerifier
    ISSUER = "https://discussionbridge.dev/operator-service"
    AUDIENCE = "discourse-discussion-bridge"
    GRACE_PERIOD_DAYS = DiscussionBridgeOperatorService::GRACE_PERIOD_DAYS
    STATUSES = %w[active past_due cancelled revoked].freeze
    LEGACY_SCHEMA_KEYS = %w[
      schema issuer audience installation_id enrollment_id entitlement_id
      operator_identity_id operator_email identity_version entitlement_version plan_id status
      issued_at paid_through_at grace_period_days grace_expires_at site_url
    ].freeze
    CURRENT_SCHEMA_KEYS = (LEGACY_SCHEMA_KEYS + ["provider_id"]).freeze

    def self.call(payload:, signature:, service:, public_key_pem: nil, now: Time.zone.now)
      claims = normalize_payload(payload)
      validate_claims!(claims, service: service, now: now)
      encoded = canonical_json(claims)
      decoded_signature = Base64.strict_decode64(signature.to_s)
      key = OpenSSL::PKey.read(public_key_pem.presence || configured_public_key)
      raise ArgumentError, "entitlement signature is invalid" unless key.verify("SHA256", decoded_signature, encoded)

      parsed = claims.merge(
        "issued_at" => Time.iso8601(claims.fetch("issued_at")),
        "paid_through_at" => Time.iso8601(claims.fetch("paid_through_at")),
        "grace_expires_at" => Time.iso8601(claims.fetch("grace_expires_at")),
      )
      parsed["provider_id"] ||= DiscussionBridge::OperatorProviderRegistry::DEFAULT_PROVIDER_ID
      parsed["entitlement_digest"] = Digest::SHA256.hexdigest(encoded)
      parsed
    rescue ArgumentError, KeyError, JSON::ParserError, OpenSSL::PKey::PKeyError
      raise ArgumentError, "entitlement is invalid"
    end

    def self.canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def self.configured_public_key
      ENV["DISCOURSE_DISCUSSION_BRIDGE_OPERATOR_ENTITLEMENT_PUBLIC_KEY"].to_s.tap do |value|
        raise ArgumentError, "entitlement verification key is unavailable" if value.blank?
      end
    end

    def self.normalize_payload(payload)
      value = payload.is_a?(String) ? JSON.parse(payload) : payload
      raise ArgumentError, "entitlement payload must be an object" unless value.is_a?(Hash)

      value.deep_stringify_keys
    end
    private_class_method :normalize_payload

    def self.validate_claims!(claims, service:, now:)
      required_keys = case claims["schema"]
                      when 1
                        LEGACY_SCHEMA_KEYS
                      when 2
                        CURRENT_SCHEMA_KEYS
                      else
                        raise ArgumentError, "entitlement schema is unsupported"
                      end
      raise ArgumentError, "entitlement fields are invalid" unless claims.keys.sort == required_keys.sort
      raise ArgumentError, "entitlement issuer is invalid" unless claims["issuer"] == ISSUER
      raise ArgumentError, "entitlement audience is invalid" unless claims["audience"] == AUDIENCE
      raise ArgumentError, "entitlement installation is invalid" unless claims["installation_id"] == service.installation_id
      raise ArgumentError, "entitlement enrollment is invalid" unless claims["enrollment_id"] == service.enrollment_id
      raise ArgumentError, "entitlement site is invalid" unless claims["site_url"] == Discourse.base_url
      raise ArgumentError, "entitlement status is invalid" if STATUSES.exclude?(claims["status"])
      provider_id = claims["provider_id"] || DiscussionBridge::OperatorProviderRegistry::DEFAULT_PROVIDER_ID
      raise ArgumentError, "entitlement provider is invalid" unless provider_id == service.provider_id
      operator_email_allowed = DiscussionBridge::OperatorProviderRegistry.operator_email_allowed?(
        provider_id: provider_id,
        email: claims["operator_email"],
      )
      raise ArgumentError, "entitlement email is invalid" unless operator_email_allowed
      raise ArgumentError, "entitlement identity is invalid" if claims["operator_identity_id"].to_s.blank?
      raise ArgumentError, "entitlement id is invalid" if claims["entitlement_id"].to_s.blank?
      raise ArgumentError, "entitlement plan is invalid" if claims["plan_id"].to_s.blank?
      raise ArgumentError, "entitlement identity version is invalid" unless claims["identity_version"].is_a?(Integer) && claims["identity_version"].positive?
      raise ArgumentError, "entitlement version is invalid" unless claims["entitlement_version"].is_a?(Integer) && claims["entitlement_version"].positive?
      raise ArgumentError, "entitlement grace period is invalid" unless claims["grace_period_days"] == GRACE_PERIOD_DAYS

      issued_at = Time.iso8601(claims.fetch("issued_at"))
      paid_through_at = Time.iso8601(claims.fetch("paid_through_at"))
      grace_expires_at = Time.iso8601(claims.fetch("grace_expires_at"))
      raise ArgumentError, "entitlement issue time is invalid" if issued_at > now + 5.minutes
      raise ArgumentError, "entitlement paid-through time is invalid" if paid_through_at < issued_at
      expected_grace = paid_through_at + GRACE_PERIOD_DAYS.days
      raise ArgumentError, "entitlement grace expiration is invalid" if (grace_expires_at - expected_grace).abs >= 1.second
    end
    private_class_method :validate_claims!

    def self.canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
      when Array
        value.map { |entry| canonicalize(entry) }
      else
        value
      end
    end
    private_class_method :canonicalize
  end
end
