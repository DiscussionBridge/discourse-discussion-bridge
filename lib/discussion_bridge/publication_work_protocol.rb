# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  module PublicationWorkProtocol
    CLAIM_REQUIRED_FIELDS = %w[worker_id correlation_id].freeze
    CLAIM_OPTIONAL_FIELDS = %w[maximum_items requested_lease_seconds].freeze
    CLAIM_RESPONSE_FIELDS = %w[publication_work claimed_at correlation_id].freeze
    RENEW_FIELDS = %w[lease_token requested_lease_seconds correlation_id].freeze
    RENEW_RESPONSE_FIELDS = %w[work_id lease_expires_at total_lease_seconds correlation_id].freeze
    ACK_REQUIRED_FIELDS = %w[
      lease_token
      resource_id
      source_revision
      source_revision_sequence
      policy_revision
      destination_policy_id
      action
      stage
      stage_token
      destination_binding
      synchronized_at
      deployment_state
      verification_state
      correlation_id
    ].freeze
    ACK_OPTIONAL_FIELDS = %w[deployed_at publicly_verified_at].freeze
    ACK_RESPONSE_FIELDS = %w[work_id accepted_stage resulting_state terminal correlation_id].freeze
    ACK_RESPONSE_OPTIONAL_FIELDS = %w[next_stage_token].freeze
    FAILURE_FIELDS = %w[lease_token error_code error_detail failed_at correlation_id].freeze
    WORK_FIELDS = %w[
      work_id
      resource_id
      connection_id
      action
      source_revision
      source_revision_sequence
      policy_revision
      destination_policy_id
      catalog_revision
      presentation_mode
      resolved_container
      resolved_taxonomy
      resolved_author
      native_limit_policy
      lease_token
      stage_token
      lease_expires_at
      attempt_count
      retry_generation
      correlation_id
    ].freeze
    DESTINATION_BINDING_FIELDS = %w[
      binding_id
      external_id
      canonical_url
      publication_revision
      content_disposition
    ].freeze
    RESOLVED_CONTAINER_FIELDS = %w[id kind].freeze
    RESOLVED_TAXONOMY_FIELDS = %w[source_id destination_id].freeze
    RESOLVED_AUTHOR_FIELDS = %w[mode destination_id].freeze
    NATIVE_LIMIT_FIELDS = %w[maximum_bytes overflow_behavior].freeze
    ACTIONS = %w[publish update hold unpublish restore].freeze
    STATES = %w[
      available
      leased
      awaiting_deployment
      awaiting_verification
      acknowledged
      retry_wait
      operator_attention
      superseded
    ].freeze
    STAGES = %w[synchronized deployed verified].freeze
    RETRYABLE_FAILURES = %w[
      transport_timeout
      source_unavailable
      destination_unavailable
      rate_limited
      build_failed
      deploy_failed
      public_verification_failed
      internal_error
    ].freeze
    TERMINAL_FAILURES = %w[
      authentication_failed
      scope_denied
      validation_failed
      content_unsupported
      identity_conflict
      destination_collision
      reconciliation_required
      operator_action_required
    ].freeze
    FAILURE_CODES = (RETRYABLE_FAILURES + TERMINAL_FAILURES).freeze
    RETRY_BACKOFF_SECONDS = [60, 300, 900].freeze
    DEFAULT_MAXIMUM_ITEMS = 1
    MAXIMUM_ITEMS = 32
    DEFAULT_LEASE_SECONDS = 300
    MAXIMUM_REQUESTED_LEASE_SECONDS = 3_600
    MAXIMUM_TOTAL_LEASE_SECONDS = 14_400
    MAXIMUM_TOTAL_ATTEMPTS = 4
    WORKER_ID_MAXIMUM_BYTES = 200
    ERROR_DETAIL_MAXIMUM_BYTES = 2_048
    WORK_ID_PATTERN = /\Adbw_[a-f0-9]{32}\z/
    TOKEN_PATTERN = /\A[a-f0-9]{64}\z/
    ISO8601_UTC_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z/
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    def self.validate_resolved_state!(work)
      exact_object!(work.resolved_container, RESOLVED_CONTAINER_FIELDS)
      valid_label!(work.resolved_container["id"], 255)
      valid_label!(work.resolved_container["kind"], 255)
      raise AdapterRequestBoundary::Error, "validation_failed" unless work.resolved_taxonomy.is_a?(Array)
      work.resolved_taxonomy.each do |item|
        exact_object!(item, RESOLVED_TAXONOMY_FIELDS)
        valid_label!(item["source_id"], 255)
        valid_label!(item["destination_id"], 255)
      end
      exact_object!(work.resolved_author, RESOLVED_AUTHOR_FIELDS)
      raise AdapterRequestBoundary::Error, "validation_failed" if
        ConnectionCapability::MAPPING_MODES.exclude?(work.resolved_author["mode"])
      destination = work.resolved_author["destination_id"]
      valid_label!(destination, 255) unless destination.nil?
      exact_object!(work.native_limit_policy, NATIVE_LIMIT_FIELDS)
      maximum = work.native_limit_policy["maximum_bytes"]
      raise AdapterRequestBoundary::Error, "validation_failed" unless maximum.is_a?(Integer) && maximum.positive?
      raise AdapterRequestBoundary::Error, "validation_failed" if
        ConnectionCapability::OVERFLOW_BEHAVIORS.exclude?(work.native_limit_policy["overflow_behavior"])
    end

    def self.validate_destination_binding!(binding)
      exact_object!(binding, DESTINATION_BINDING_FIELDS)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        AdapterProtocolRecords::BINDING_ID_PATTERN.match?(binding["binding_id"].to_s)
      %w[external_id canonical_url publication_revision].each do |field|
        valid_label!(binding[field], field == "canonical_url" ? 2_048 : 255)
      end
      raise AdapterRequestBoundary::Error, "validation_failed" if
        BridgeRecordRequest::CONTENT_DISPOSITIONS.exclude?(binding["content_disposition"])
    end

    def self.exact_object!(value, fields)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        value.is_a?(Hash) && value.keys.map(&:to_s).sort == fields.sort
    end

    def self.valid_label!(value, maximum)
      raise AdapterRequestBoundary::Error, "validation_failed" unless
        value.is_a?(String) && value.valid_encoding? && value.present? && value == value.strip &&
          value.bytesize <= maximum && !CONTROL_PATTERN.match?(value)
    end

    def self.parse_time!(value)
      raise AdapterRequestBoundary::Error, "malformed_value" unless
        value.is_a?(String) && ISO8601_UTC_PATTERN.match?(value)

      Time.iso8601(value)
    rescue ArgumentError
      raise AdapterRequestBoundary::Error, "malformed_value"
    end

    def self.token
      SecureRandom.hex(32)
    end

    def self.token_digest(value)
      Digest::SHA256.hexdigest(value.to_s)
    end

    def self.secure_token_match?(digest, value)
      return false unless digest.is_a?(String) && TOKEN_PATTERN.match?(value.to_s)

      ActiveSupport::SecurityUtils.secure_compare(digest, token_digest(value))
    end

    def self.payload_digest(payload)
      Digest::SHA256.hexdigest(JSON.generate(canonical(payload.deep_stringify_keys)))
    end

    def self.safe_error_detail!(detail, lease_token:)
      valid_label!(detail, ERROR_DETAIL_MAXIMUM_BYTES)
      forbidden = [lease_token, "X-DiscussionBridge-Secret", "Authorization:"].compact
      raise AdapterRequestBoundary::Error, "validation_failed" if forbidden.any? { |value| detail.include?(value) }

      detail
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
  end
end
