# frozen_string_literal: true

require "base64"
require "cgi"
require "digest"
require "json"
require "net/http"
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

    def initialize(peer)
      @peer = peer
      @origin = URI.parse(peer.remote_origin)
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
      query = URI.encode_www_form(source_revision: source_revision)
      payload = get(
        "/discussion-bridge/v1/source-topics/#{topic_id}.json?#{query}",
        correlation_id: correlation_id,
        maximum_bytes: SOURCE_DETAIL_MAXIMUM_BYTES,
      )
      transport = payload.fetch("content_transport")
      return [payload, nil] if transport["mode"] == "inline"

      chunks = (1..transport.fetch("chunk_count")).map do |chunk|
        content_query = URI.encode_www_form(source_revision: source_revision, chunk: chunk)
        response = get(
          "/discussion-bridge/v1/source-topics/#{topic_id}/content.json?#{content_query}",
          correlation_id: correlation_id,
          maximum_bytes: CONTENT_CHUNK_MAXIMUM_BYTES,
        )
        validate_chunk!(response, chunk: chunk, descriptor: transport)
      end
      content = chunks.join
      raise Error, "integrity_failed" unless content.bytesize == transport.fetch("byte_length") &&
        Digest::SHA256.hexdigest(content) == transport.fetch("sha256")

      [payload, content]
    end

    def acknowledge(work:, destination_binding:, correlation_id:)
      put(
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
      )
    end

    private

    def get(path, correlation_id:, maximum_bytes: JSON_MAXIMUM_BYTES)
      request(Net::HTTP::Get, path, nil, correlation_id: correlation_id, maximum_bytes: maximum_bytes)
    end

    def post(path, body, correlation_id:)
      request(Net::HTTP::Post, path, body, correlation_id: correlation_id)
    end

    def put(path, body, correlation_id:)
      request(Net::HTTP::Put, path, body, correlation_id: correlation_id)
    end

    def request(request_class, path, body, correlation_id:, maximum_bytes: JSON_MAXIMUM_BYTES)
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
      response_body = +""
      FinalDestination::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: true,
        open_timeout: CONNECT_TIMEOUT_SECONDS,
      ) do |http|
        http.read_timeout = RESPONSE_TIMEOUT_SECONDS
        http.write_timeout = RESPONSE_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
        http.request(request) do |response|
          response_code = response.code.to_i
          response_type = response["content-type"].to_s
          response.read_body do |chunk|
            response_body << chunk
            raise Error, "request_too_large" if response_body.bytesize > maximum_bytes
          end
        end
      end
      raise Error, "destination_unavailable" unless response_type.start_with?("application/json")

      payload = JSON.parse(response_body)
      unless response_code.between?(200, 299)
        code = payload["error_code"]
        raise Error, AdapterRequestBoundary::ERROR_STATUSES.key?(code) ? code : "destination_unavailable"
      end
      payload
    rescue Error
      raise
    rescue JSON::ParserError, KeyError, URI::InvalidURIError
      raise Error, "validation_failed"
    rescue StandardError
      raise Error, "destination_unavailable"
    end

    def validate_chunk!(payload, chunk:, descriptor:)
      unless payload.keys.sort == SourcePublicationProtocol::CONTENT_FIELDS.sort &&
          payload.fetch("source_revision").is_a?(String) &&
          payload.fetch("chunk") == chunk &&
          payload.fetch("chunk_count") == descriptor.fetch("chunk_count")
        raise Error, "validation_failed"
      end
      decoded = Base64.strict_decode64(payload.fetch("content_base64"))
      unless decoded.bytesize == payload.fetch("decoded_bytes") &&
          Digest::SHA256.hexdigest(decoded) == payload.fetch("chunk_sha256")
        raise Error, "integrity_failed"
      end
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
