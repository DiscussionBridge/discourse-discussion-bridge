# frozen_string_literal: true

require "base64"
require "cgi"
require "digest"
require "json"
require "net/http"
require "timeout"
require "uri"

module DiscussionBridge
  class NetworkPeerClient
    class Error < StandardError
      attr_reader :error_code

      def initialize(error_code)
        @error_code = error_code
        super(error_code)
      end
    end

    JSON_MAXIMUM_BYTES = 65_536
    SOURCE_DETAIL_MAXIMUM_BYTES = 131_072
    CONTENT_CHUNK_MAXIMUM_BYTES = 65_536
    CONNECT_TIMEOUT_SECONDS = 5
    RESPONSE_TIMEOUT_SECONDS = 15
    HTTP_EXCHANGE_TIMEOUT_SECONDS = 30
    WORK_CYCLE_TIMEOUT_SECONDS = 240
    FAILURE_REPORT_TIMEOUT_SECONDS = 30

    class TransportDeadlineExceeded < StandardError
    end
    private_constant :TransportDeadlineExceeded

    def initialize(peer, monotonic_clock: nil)
      @peer = peer
      @origin = URI.parse(peer.remote_origin)
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @work_cycle_deadline = nil
    end

    def start_work_cycle!
      raise Error, "validation_failed" if @work_cycle_deadline

      @work_cycle_deadline = new_deadline(WORK_CYCLE_TIMEOUT_SECONDS)
    end

    def ensure_work_cycle_active!
      ensure_deadline!(@work_cycle_deadline) if @work_cycle_deadline
      true
    rescue TransportDeadlineExceeded
      raise Error, "transport_timeout"
    end

    def finish_work_cycle!
      @work_cycle_deadline = nil
    end

    def claim(correlation_id:)
      post(
        "/discussion-bridge/v1/publication-work/claim.json",
        {
          worker_id: worker_id,
          maximum_items: 1,
          requested_lease_seconds: PublicationWorkProtocol::DEFAULT_LEASE_SECONDS,
          correlation_id: correlation_id,
        },
        correlation_id: correlation_id,
      ).fetch("publication_work")
    end

    def bridge_record(resource_id, correlation_id:)
      get(
        "/discussion-bridge/v1/bridge-records/#{CGI.escape(resource_id)}.json",
        correlation_id: correlation_id,
      ).fetch("bridge_record")
    end

    def source_detail(topic_id:, source_revision:, correlation_id:)
      operation_deadline = @work_cycle_deadline || new_deadline(WORK_CYCLE_TIMEOUT_SECONDS)
      query = URI.encode_www_form(source_revision: source_revision)
      payload = get(
        "/discussion-bridge/v1/source-topics/#{topic_id}.json?#{query}",
        correlation_id: correlation_id,
        maximum_bytes: SOURCE_DETAIL_MAXIMUM_BYTES,
        operation_deadline: operation_deadline,
      )
      validate_source_descriptor!(
        payload,
        topic_id: topic_id,
        source_revision: source_revision,
      )
      transport = payload.fetch("content_transport")
      return [payload, nil] if transport["mode"] == "inline"

      chunks = (1..transport.fetch("chunk_count")).map do |chunk|
        content_query = URI.encode_www_form(source_revision: source_revision, chunk: chunk)
        response = get(
          "/discussion-bridge/v1/source-topics/#{topic_id}/content.json?#{content_query}",
          correlation_id: correlation_id,
          maximum_bytes: CONTENT_CHUNK_MAXIMUM_BYTES,
          operation_deadline: operation_deadline,
        )
        validate_chunk!(
          response,
          chunk: chunk,
          descriptor: transport,
          source_revision: source_revision,
        )
      end
      content = chunks.join
      content.force_encoding(Encoding::UTF_8)
      raise Error, "integrity_failed" unless content.bytesize == transport.fetch("byte_length") &&
        Digest::SHA256.hexdigest(content) == transport.fetch("sha256") && content.valid_encoding?
      ensure_deadline!(operation_deadline)

      [payload, content]
    rescue TransportDeadlineExceeded
      raise Error, "transport_timeout"
    end

    def acknowledge(work:, destination_binding:, correlation_id:)
      response = put(
        "/discussion-bridge/v1/publication-work/#{CGI.escape(work.fetch("work_id"))}/acknowledgement.json",
        {
          lease_token: work.fetch("lease_token"),
          resource_id: work.fetch("resource_id"),
          source_revision: work.fetch("source_revision"),
          source_revision_sequence: work.fetch("source_revision_sequence"),
          policy_revision: work.fetch("policy_revision"),
          destination_policy_id: work.fetch("destination_policy_id"),
          action: work.fetch("action"),
          stage: "synchronized",
          stage_token: work.fetch("stage_token"),
          destination_binding: destination_binding,
          synchronized_at: Time.zone.now.iso8601(6),
          deployment_state: "not_required",
          verification_state: "not_required",
          correlation_id: correlation_id,
        },
        correlation_id: correlation_id,
      )
      expected = {
        "work_id" => work.fetch("work_id"),
        "accepted_stage" => "synchronized",
        "resulting_state" => "acknowledged",
        "terminal" => true,
        "correlation_id" => correlation_id,
      }
      raise Error, "validation_failed" unless response == expected

      response
    end

    def fail(work:, error_code:, correlation_id:)
      put(
        "/discussion-bridge/v1/publication-work/#{CGI.escape(work.fetch("work_id"))}/failure.json",
        {
          lease_token: work.fetch("lease_token"),
          error_code: error_code,
          error_detail: "The Discourse network destination could not apply this bounded work item.",
          failed_at: Time.zone.now.iso8601(6),
          correlation_id: correlation_id,
        },
        correlation_id: correlation_id,
        operation_deadline: new_deadline(FAILURE_REPORT_TIMEOUT_SECONDS),
      )
    end

    private

    def get(path, correlation_id:, maximum_bytes: JSON_MAXIMUM_BYTES, operation_deadline: @work_cycle_deadline)
      request(
        Net::HTTP::Get,
        path,
        nil,
        correlation_id: correlation_id,
        maximum_bytes: maximum_bytes,
        operation_deadline: operation_deadline,
      )
    end

    def post(path, body, correlation_id:, operation_deadline: @work_cycle_deadline)
      request(
        Net::HTTP::Post,
        path,
        body,
        correlation_id: correlation_id,
        operation_deadline: operation_deadline,
      )
    end

    def put(path, body, correlation_id:, operation_deadline: @work_cycle_deadline)
      request(
        Net::HTTP::Put,
        path,
        body,
        correlation_id: correlation_id,
        operation_deadline: operation_deadline,
      )
    end

    def request(
      request_class,
      path,
      body,
      correlation_id:,
      maximum_bytes: JSON_MAXIMUM_BYTES,
      operation_deadline: nil
    )
      uri = URI.join("#{@peer.remote_origin}/", path.delete_prefix("/"))
      raise Error, "scope_denied" unless uri.scheme == "https" && same_origin?(uri)

      request = request_class.new(uri.request_uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json" if body
      request["User-Agent"] = "DiscussionBridge-Discourse-Network/#{DiscussionBridge::VERSION}"
      request[AdapterRequestBoundary::CONNECTION_HEADER] = @peer.remote_connection_id
      request[AdapterRequestBoundary::SECRET_HEADER] = @peer.remote_secret
      request[AdapterRequestBoundary::CONTRACT_HEADER] = DiscussionBridge::CONTRACT_VERSION
      request[AdapterRequestBoundary::CORRELATION_HEADER] = correlation_id
      request.body = JSON.generate(body) if body

      response_code = nil
      response_type = nil
      response_correlation = nil
      response_body = +""
      request_deadline = exchange_deadline(operation_deadline)
      Timeout.timeout(remaining_seconds!(request_deadline), TransportDeadlineExceeded) do
        FinalDestination::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: bounded_timeout(CONNECT_TIMEOUT_SECONDS, request_deadline),
        ) do |http|
          apply_session_timeouts!(http, request_deadline)
          http.request(request) do |response|
            response_code = response.code.to_i
            response_maximum_bytes = if response_code.between?(200, 299)
              maximum_bytes
            else
              AdapterRequestBoundary::MAX_ERROR_JSON_BYTES
            end
            response_type = response["content-type"].to_s
            response_correlation = response[AdapterRequestBoundary::CORRELATION_HEADER]
            response.read_body do |chunk|
              if response_body.bytesize + chunk.bytesize > response_maximum_bytes
                raise Error, "request_too_large"
              end

              response_body << chunk

              apply_session_timeouts!(http, request_deadline)
            end
          end
        end
      end
      ensure_deadline!(request_deadline)
      raise Error, "destination_unavailable" unless response_type.start_with?("application/json")

      valid_response_correlation = AdapterRequestBoundary.valid_correlation?(response_correlation) &&
        response_correlation == correlation_id
      raise Error, "validation_failed" unless valid_response_correlation

      payload = JSON.parse(response_body)
      raise Error, "validation_failed" unless payload["correlation_id"] == correlation_id
      unless response_code.between?(200, 299)
        code = payload["error_code"]
        raise Error, AdapterRequestBoundary::ERROR_STATUSES.key?(code) ? code : "destination_unavailable"
      end
      payload
    rescue TransportDeadlineExceeded, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise Error, "transport_timeout"
    rescue Error
      raise
    rescue JSON::ParserError, KeyError, URI::InvalidURIError
      raise Error, "validation_failed"
    rescue StandardError
      raise Error, "destination_unavailable"
    end

    def exchange_deadline(operation_deadline)
      request_deadline = new_deadline(HTTP_EXCHANGE_TIMEOUT_SECONDS)
      operation_deadline ? [operation_deadline, request_deadline].min : request_deadline
    end

    def new_deadline(seconds)
      monotonic_now + seconds
    end

    def ensure_deadline!(deadline)
      remaining_seconds!(deadline)
    end

    def remaining_seconds!(deadline)
      remaining = deadline - monotonic_now
      raise TransportDeadlineExceeded, "network transport deadline exceeded" unless remaining.positive?

      remaining
    end

    def bounded_timeout(maximum, deadline)
      [maximum, remaining_seconds!(deadline)].min
    end

    def apply_session_timeouts!(http, deadline)
      timeout = bounded_timeout(RESPONSE_TIMEOUT_SECONDS, deadline)
      http.read_timeout = timeout
      http.write_timeout = timeout if http.respond_to?(:write_timeout=)
    end

    def monotonic_now
      @monotonic_clock.call
    end

    def validate_source_descriptor!(payload, topic_id:, source_revision:)
      raise Error, "validation_failed" unless
        payload.is_a?(Hash) && payload.keys.sort == SourcePublicationProtocol::DETAIL_FIELDS.sort &&
          payload["topic_id"] == topic_id && payload["source_revision"] == source_revision

      transport = payload["content_transport"]
      raise Error, "validation_failed" unless transport.is_a?(Hash)
      return if transport["mode"] == "inline"

      byte_length = transport["byte_length"]
      chunk_count = transport["chunk_count"]
      chunk_maximum = transport["decoded_chunk_maximum_bytes"]
      maximum_chunks = (SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES.to_f /
        SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES).ceil
      valid = transport.keys.sort == SourcePublicationProtocol::CHUNK_DESCRIPTOR_FIELDS.sort &&
        byte_length.is_a?(Integer) &&
        byte_length.between?(SourcePublicationProtocol::INLINE_MAXIMUM_BYTES + 1,
                            SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES) &&
        chunk_maximum == SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES &&
        chunk_count.is_a?(Integer) && chunk_count.between?(1, maximum_chunks) &&
        chunk_count == (byte_length.to_f / chunk_maximum).ceil
      raise Error, "validation_failed" unless valid
    end

    def validate_chunk!(payload, chunk:, descriptor:, source_revision:)
      unless payload.keys.sort == SourcePublicationProtocol::CONTENT_FIELDS.sort &&
          payload.fetch("source_revision") == source_revision &&
          payload.fetch("chunk") == chunk &&
          payload.fetch("chunk_count") == descriptor.fetch("chunk_count")
        raise Error, "validation_failed"
      end
      decoded = Base64.strict_decode64(payload.fetch("content_base64"))
      valid = decoded.bytesize == payload.fetch("decoded_bytes") &&
          decoded.bytesize.between?(1, SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES) &&
          (chunk == descriptor.fetch("chunk_count") ||
            decoded.bytesize == SourcePublicationProtocol::CHUNK_MAXIMUM_BYTES) &&
          Digest::SHA256.hexdigest(decoded) == payload.fetch("chunk_sha256")
      raise Error, "integrity_failed" unless valid

      decoded
    rescue ArgumentError, KeyError
      raise Error, "validation_failed"
    end

    def same_origin?(uri)
      uri.scheme == @origin.scheme && uri.host == @origin.host && uri.port == @origin.port
    end

    def worker_id
      identity = DiscussionBridgeForumIdentity.current
      "discourse-network:#{identity.forum_id}"
    end
  end
end
