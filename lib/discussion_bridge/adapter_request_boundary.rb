# frozen_string_literal: true

require "json"
require "stringio"

module DiscussionBridge
  module AdapterRequestBoundary
    CONTRACT_VERSION = "0.2.0-alpha.22"
    MAX_JSON_BYTES = 65_536
    MAX_CORRELATION_BYTES = 200
    MAX_ERROR_JSON_BYTES = 4096
    CONNECTION_ID_PATTERN = /\Adbc_[a-f0-9]{24}\z/
    CONTROL_PATTERN = /[\x00-\x1f\x7f]/
    ERROR_STATUSES = {
      "invalid_json" => 400, "unknown_field" => 400, "malformed_value" => 400,
      "authentication_failed" => 401, "contract_version_mismatch" => 401,
      "scope_denied" => 403, "direction_denied" => 403, "policy_denied" => 403,
      "not_found" => 404, "revision_not_found" => 404,
      "reconciliation_required" => 409, "revision_conflict" => 409,
      "identity_conflict" => 409, "destination_collision" => 409,
      "lease_conflict" => 409, "work_superseded" => 409,
      "catalog_revision_conflict" => 409, "cursor_snapshot_mismatch" => 409,
      "stage_conflict" => 409, "operation_replay_mismatch" => 409,
      "snapshot_expired" => 410, "revision_superseded" => 410,
      "work_expired" => 410, "url_retired" => 410,
      "request_too_large" => 413, "unsupported_media_type" => 415,
      "validation_failed" => 422, "content_unsupported" => 422,
      "integrity_failed" => 422, "lease_limit_exceeded" => 422,
      "rate_limited" => 429, "internal_error" => 500,
      "temporarily_unavailable" => 503,
    }.freeze

    class Error < StandardError
      attr_reader :error_code

      def initialize(error_code)
        ERROR_STATUSES.fetch(error_code)
        @error_code = error_code
        super("DiscussionBridge request failed: #{error_code}.")
      end
    end

    class UniqueObject < Hash
      def []=(key, value)
        raise Error.new("invalid_json") if key?(key)
        super
      end
    end

    def self.valid_correlation?(value)
      return false unless value.is_a?(String)
      utf8 = value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? && !utf8.strip.empty? &&
        utf8.bytesize <= MAX_CORRELATION_BYTES && !CONTROL_PATTERN.match?(utf8)
    end

    def self.parse(text)
      raise Error.new("invalid_json") unless text.is_a?(String)
      raise Error.new("request_too_large") if text.bytesize > MAX_JSON_BYTES
      text = text.dup.force_encoding(Encoding::UTF_8)
      raise Error.new("invalid_json") unless text.valid_encoding?
      # JSON.parse (unlike JSON.load) does not instantiate json_class additions.
      parsed = JSON.parse(text, object_class: UniqueObject, max_nesting: 64)
      # Duplicate detection belongs to lexical JSON ingestion. A strict parser
      # Hash must not survive into ActiveSupport deep_dup, which reassigns keys
      # already present in its shallow copy and would falsely report duplicates.
      ordinary_objects(parsed)
    rescue JSON::ParserError, JSON::NestingError
      raise Error.new("invalid_json")
    end

    def self.ordinary_objects(value)
      case value
      when Hash
        value.to_h { |key, child| [key, ordinary_objects(child)] }
      when Array
        value.map { |child| ordinary_objects(child) }
      else
        value
      end
    end

    def self.error_payload(code, correlation)
      error = Error.new(code)
      value = { error_code: code, message: error.message, correlation_id: correlation }
      raise "oversized error envelope" if JSON.generate(value).bytesize > MAX_ERROR_JSON_BYTES
      value
    end
  end

  # Runs before ActionController instrumentation can request parsed parameters.
  # The limit is enforced on actual bytes even when Content-Length is absent.
  class BoundedAdapterBody
    RESOLVE_PATH = %r{\A/discussion-bridge/v1/bridge-records/resolve(?:\.json)?\z}
    CATALOG_PATH = %r{\A/discussion-bridge/v1/platform-catalog(?:\.json)?\z}
    POLICY_CONFIGURATION_PATH = %r{\A/discussion-bridge/admin/content-connections/[1-9]\d*/destination-policies(?:\.json)?\z}
    WORK_PATH = %r{\A/discussion-bridge/v1/publication-work/(?:claim|[^/]+/renew)(?:\.json)?\z}

    def initialize(app)
      @app = app
    end

    def call(env)
      native_configuration = env["REQUEST_METHOD"] == "PUT" && POLICY_CONFIGURATION_PATH.match?(env["PATH_INFO"].to_s)
      bounded = native_configuration || (env["REQUEST_METHOD"] == "POST" && RESOLVE_PATH.match?(env["PATH_INFO"].to_s)) ||
        (env["REQUEST_METHOD"] == "PUT" && CATALOG_PATH.match?(env["PATH_INFO"].to_s)) ||
        (env["REQUEST_METHOD"] == "POST" && WORK_PATH.match?(env["PATH_INFO"].to_s))
      return @app.call(env) unless bounded
      supplied = env["HTTP_X_DISCUSSIONBRIDGE_CORRELATION"]
      valid_correlation = AdapterRequestBoundary.valid_correlation?(supplied)
      correlation = valid_correlation ? supplied.dup.force_encoding(Encoding::UTF_8) : SecureRandom.uuid
      begin
        raise AdapterRequestBoundary::Error.new("validation_failed") unless valid_correlation || native_configuration
        unless native_configuration || env["HTTP_X_DISCUSSIONBRIDGE_CONTRACT"] == AdapterRequestBoundary::CONTRACT_VERSION
          raise AdapterRequestBoundary::Error.new("contract_version_mismatch")
        end
        if env["CONTENT_LENGTH"].to_i > AdapterRequestBoundary::MAX_JSON_BYTES
          raise AdapterRequestBoundary::Error.new("request_too_large")
        end
        unless env["CONTENT_TYPE"].to_s.split(";").first == "application/json"
          raise AdapterRequestBoundary::Error.new("unsupported_media_type")
        end
        input = env.fetch("rack.input")
        bytes = input.read(AdapterRequestBoundary::MAX_JSON_BYTES + 1)
        AdapterRequestBoundary.parse(bytes)
        env["rack.input"] = StringIO.new(bytes)
      rescue AdapterRequestBoundary::Error => error
        body = JSON.generate(AdapterRequestBoundary.error_payload(error.error_code, correlation))
        return [AdapterRequestBoundary::ERROR_STATUSES.fetch(error.error_code),
                { "content-type" => "application/json; charset=utf-8",
                  "x-discussionbridge-correlation" => correlation }, [body]]
      end
      @app.call(env)
    end
  end
end
