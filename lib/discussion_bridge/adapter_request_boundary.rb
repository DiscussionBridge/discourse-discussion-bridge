# frozen_string_literal: true

require "json"
require "uri"

module DiscussionBridge
  module AdapterRequestBoundary
    CONNECTION_HEADER = "X-DiscussionBridge-Connection"
    SECRET_HEADER = "X-DiscussionBridge-Secret"
    CONTRACT_HEADER = "X-DiscussionBridge-Contract"
    CORRELATION_HEADER = "X-DiscussionBridge-Correlation"
    CONTRACT_VERSION = "0.2.0-alpha.21"
    CONNECTION_ID_PATTERN = /\Adbc_[a-f0-9]{24}\z/
    MAX_CORRELATION_BYTES = 200
    MAX_ERROR_JSON_BYTES = 4096
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/

    ERROR_STATUSES = {
      "invalid_json" => :bad_request,
      "unknown_field" => :bad_request,
      "malformed_value" => :bad_request,
      "authentication_failed" => :unauthorized,
      "contract_version_mismatch" => :unauthorized,
      "scope_denied" => :forbidden,
      "direction_denied" => :forbidden,
      "policy_denied" => :forbidden,
      "not_found" => :not_found,
      "revision_not_found" => :not_found,
      "reconciliation_required" => :conflict,
      "revision_conflict" => :conflict,
      "identity_conflict" => :conflict,
      "destination_collision" => :conflict,
      "lease_conflict" => :conflict,
      "work_superseded" => :conflict,
      "catalog_revision_conflict" => :conflict,
      "cursor_snapshot_mismatch" => :conflict,
      "stage_conflict" => :conflict,
      "operation_replay_mismatch" => :conflict,
      "snapshot_expired" => :gone,
      "revision_superseded" => :gone,
      "work_expired" => :gone,
      "url_retired" => :gone,
      "request_too_large" => :payload_too_large,
      "unsupported_media_type" => :unsupported_media_type,
      "validation_failed" => :unprocessable_entity,
      "content_unsupported" => :unprocessable_entity,
      "integrity_failed" => :unprocessable_entity,
      "lease_limit_exceeded" => :unprocessable_entity,
      "rate_limited" => :too_many_requests,
      "internal_error" => :internal_server_error,
      "temporarily_unavailable" => :service_unavailable,
    }.freeze

    ERROR_MESSAGES = {
      "invalid_json" => "The request body is not valid JSON.",
      "unknown_field" => "The request contains a field that is not defined by the contract.",
      "malformed_value" => "The request contains a malformed value.",
      "authentication_failed" => "Content Connection authentication failed.",
      "contract_version_mismatch" => "The request does not use the required Adapter Protocol version.",
      "scope_denied" => "The authenticated Content Connection does not authorize the requested scope.",
      "direction_denied" => "The authenticated Content Connection does not authorize the requested direction.",
      "policy_denied" => "The request is not permitted by the effective forum policy.",
      "not_found" => "The requested DiscussionBridge resource was not found.",
      "revision_not_found" => "The requested source revision was not found.",
      "reconciliation_required" => "The request requires operator reconciliation.",
      "revision_conflict" => "The request conflicts with the authoritative source revision.",
      "identity_conflict" => "The request conflicts with an existing stable identity.",
      "destination_collision" => "The requested destination identity is already owned.",
      "lease_conflict" => "The publication lease is not current.",
      "work_superseded" => "The publication work has been superseded.",
      "catalog_revision_conflict" => "The platform catalog revision is not current.",
      "cursor_snapshot_mismatch" => "The cursor does not belong to the active snapshot.",
      "stage_conflict" => "The requested publication stage transition is not valid.",
      "operation_replay_mismatch" => "The operation identifier was replayed with different content.",
      "snapshot_expired" => "The requested snapshot has expired.",
      "revision_superseded" => "The requested revision is no longer retained.",
      "work_expired" => "The publication work is no longer available.",
      "url_retired" => "The requested URL has been retired.",
      "request_too_large" => "The request exceeds the endpoint's documented size limit.",
      "unsupported_media_type" => "The request must use application/json.",
      "validation_failed" => "The request does not satisfy the Adapter Protocol.",
      "content_unsupported" => "The supplied content cannot be represented safely.",
      "integrity_failed" => "The supplied content failed integrity verification.",
      "lease_limit_exceeded" => "The requested lease exceeds the permitted limit.",
      "rate_limited" => "The request is temporarily rate limited.",
      "internal_error" => "The request could not be completed.",
      "temporarily_unavailable" => "DiscussionBridge is temporarily unavailable.",
    }.freeze

    class Error < StandardError
      attr_reader :error_code, :status

      def initialize(error_code)
        raise ArgumentError, "unknown Adapter Protocol error code" unless ERROR_STATUSES.key?(error_code)

        @error_code = error_code
        @status = ERROR_STATUSES.fetch(error_code)
        super(ERROR_MESSAGES.fetch(error_code))
      end
    end

    def self.valid_correlation?(value)
      value.is_a?(String) && value.valid_encoding? && value.present? &&
        value.bytesize <= MAX_CORRELATION_BYTES && !CONTROL_PATTERN.match?(value)
    end

    def self.error_payload(error_code, correlation_id)
      payload = {
        error_code: error_code,
        message: ERROR_MESSAGES.fetch(error_code),
        correlation_id: correlation_id,
      }
      raise "Adapter Protocol error envelope exceeds its bound" if JSON.generate(payload).bytesize > MAX_ERROR_JSON_BYTES

      payload
    end
  end
end
