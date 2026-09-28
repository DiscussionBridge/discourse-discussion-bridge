# frozen_string_literal: true

require "digest"
require "openssl"
require "time"

module DiscussionBridge
  class OperatorEntitlementVerifier
    class VerificationError < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.tr("_", " "))
      end
    end

    SIGNING_DOMAIN = "DiscussionBridge-Operator-Service-Entitlement-v1\n"
    ENTITLEMENT_VERSION = 1
    MAXIMUM_LIFETIME_SECONDS = 31_536_000
    MAXIMUM_GRACE_SECONDS = 604_800
    REQUIRED_FIELDS = %w[
      entitlement_version entitlement_id provider_id provider_name forum_id issuer_id issued_at
      not_before expires_at grace_until scopes key_id signature
    ].freeze
    ALLOWED_SCOPES = %w[
      observe_health observe_publication retry_retryable_work prepare_reconciliation
      apply_customer_approved_reconciliation prepare_connection_change
      apply_customer_approved_connection_change request_backup prepare_upgrade
      apply_customer_approved_upgrade
    ].freeze
    ID_PATTERNS = {
      "entitlement_id" => /\Adbe_[a-f0-9]{32}\z/,
      "provider_id" => /\Adbp_[a-f0-9]{32}\z/,
      "forum_id" => /\Adbf_[a-f0-9]{32}\z/,
      "issuer_id" => /\Adbi_[a-f0-9]{32}\z/,
    }.freeze

    def self.call(payload:, enrollment:, actor:, at: Time.zone.now)
      claims = normalize(payload)
      trusted_key = resolve_key(claims, at: at)
      verify_signature!(claims, trusted_key)
      validate_claims!(claims, enrollment: enrollment, at: at)

      unsigned = claims.except("signature")
      canonical = DiscussionBridge::OperatorCanonicalJson.generate(unsigned)
      payload_sha256 = Digest::SHA256.hexdigest(SIGNING_DOMAIN + canonical)
      existing = DiscussionBridgeOperatorEntitlement.find_by(entitlement_id: claims.fetch("entitlement_id"))
      if existing
        if existing.payload_sha256 == payload_sha256 && existing.signature == claims.fetch("signature")
          state = existing.effective_state(at: at)
          raise VerificationError, "entitlement_revoked" if state == "revoked"
          raise VerificationError, "entitlement_replaced" if state == "replaced"
          raise VerificationError, "entitlement_expired" if state == "expired"

          return existing
        end

        raise VerificationError, "entitlement_replaced"
      end

      DiscussionBridgeOperatorEntitlement.create!(
        entitlement_id: claims.fetch("entitlement_id"),
        provider_id: claims.fetch("provider_id"),
        provider_name: claims.fetch("provider_name"),
        forum_id: claims.fetch("forum_id"),
        issuer_id: claims.fetch("issuer_id"),
        key_id: claims.fetch("key_id"),
        entitlement_version: claims.fetch("entitlement_version"),
        scopes: claims.fetch("scopes"),
        signature: claims.fetch("signature"),
        payload_sha256: payload_sha256,
        payload: claims,
        state: "active",
        issued_at: parse_time(claims.fetch("issued_at")),
        not_before: parse_time(claims.fetch("not_before")),
        expires_at: parse_time(claims.fetch("expires_at")),
        grace_until: parse_time(claims.fetch("grace_until")),
        activated_at: at,
        enrolled_by: actor,
      )
    rescue ActiveRecord::RecordNotUnique
      raise VerificationError, "entitlement_replaced"
    end

    def self.normalize(payload)
      raise VerificationError, "entitlement_invalid_signature" unless payload.is_a?(Hash)

      claims = payload.deep_stringify_keys
      raise VerificationError, "entitlement_invalid_signature" unless claims.keys.sort == REQUIRED_FIELDS.sort

      claims
    end
    private_class_method :normalize

    def self.resolve_key(claims, at:)
      issuer_id = claims["issuer_id"]
      key_id = claims["key_id"]
      key = DiscussionBridgeOperatorTrustedKey.find_by(issuer_id: issuer_id, key_id: key_id)
      raise VerificationError, "entitlement_invalid_signature" unless key&.available_for_issuance?(at: at)

      key
    end
    private_class_method :resolve_key

    def self.verify_signature!(claims, trusted_key)
      signature = DiscussionBridge::OperatorEncoding.decode_base64url(
        claims["signature"], expected_bytes: 64,
      )
      public_key = DiscussionBridge::OperatorEncoding.decode_base64url(
        trusted_key.public_key_base64url, expected_bytes: 32,
      )
      raise VerificationError, "entitlement_invalid_signature" unless signature && public_key

      unsigned = claims.except("signature")
      message = SIGNING_DOMAIN + DiscussionBridge::OperatorCanonicalJson.generate(unsigned)
      algorithm = OpenSSL::ASN1::Sequence.new([
        OpenSSL::ASN1::ObjectId.new("ED25519"),
      ])
      subject_public_key = OpenSSL::ASN1::Sequence.new([
        algorithm,
        OpenSSL::ASN1::BitString.new(public_key),
      ]).to_der
      key = OpenSSL::PKey.read(subject_public_key)
      raise VerificationError, "entitlement_invalid_signature" unless key.verify(nil, signature, message)
    rescue OpenSSL::PKey::PKeyError, DiscussionBridge::OperatorCanonicalJson::InvalidValue
      raise VerificationError, "entitlement_invalid_signature"
    end
    private_class_method :verify_signature!

    def self.validate_claims!(claims, enrollment:, at:)
      ID_PATTERNS.each do |field, pattern|
        raise VerificationError, "entitlement_invalid_signature" unless pattern.match?(claims[field].to_s)
      end
      raise VerificationError, "entitlement_invalid_signature" unless
        claims["entitlement_version"] == ENTITLEMENT_VERSION
      validate_bounded_string!(claims["provider_name"], 200)
      validate_bounded_string!(claims["key_id"], 200)
      scopes = claims["scopes"]
      raise VerificationError, "scope_denied" unless scopes.is_a?(Array) && scopes.any? && scopes.uniq == scopes
      raise VerificationError, "scope_denied" if (scopes - ALLOWED_SCOPES).any?

      issued_at = parse_time(claims.fetch("issued_at"))
      not_before = parse_time(claims.fetch("not_before"))
      expires_at = parse_time(claims.fetch("expires_at"))
      grace_until = parse_time(claims.fetch("grace_until"))
      raise VerificationError, "entitlement_invalid_signature" if not_before < issued_at
      raise VerificationError, "entitlement_invalid_signature" if expires_at <= not_before
      raise VerificationError, "entitlement_invalid_signature" if
        expires_at - issued_at > MAXIMUM_LIFETIME_SECONDS
      raise VerificationError, "entitlement_invalid_signature" if grace_until < expires_at
      raise VerificationError, "entitlement_invalid_signature" if
        grace_until - expires_at > MAXIMUM_GRACE_SECONDS
      raise VerificationError, "entitlement_wrong_forum" unless claims["forum_id"] == enrollment.forum_id
      raise VerificationError, "scope_denied" unless claims["provider_id"] == enrollment.provider_id
      raise VerificationError, "entitlement_not_yet_valid" if at < not_before
      raise VerificationError, "entitlement_expired" if at > grace_until
    rescue TypeError
      raise VerificationError, "entitlement_invalid_signature"
    end
    private_class_method :validate_claims!

    def self.validate_bounded_string!(value, maximum_bytes)
      valid = value.is_a?(String) && value.valid_encoding? && value.present? &&
        value.bytesize <= maximum_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise VerificationError, "entitlement_invalid_signature" unless valid
    end
    private_class_method :validate_bounded_string!

    def self.parse_time(value)
      valid = value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/)
      raise VerificationError, "entitlement_invalid_signature" unless valid

      Time.iso8601(value)
    rescue ArgumentError
      raise VerificationError, "entitlement_invalid_signature"
    end
    private_class_method :parse_time
  end
end
