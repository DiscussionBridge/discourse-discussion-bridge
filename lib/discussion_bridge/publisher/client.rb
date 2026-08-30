# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module ::DiscussionBridge
  module Publisher
    class Client
      MAX_RESPONSE_BYTES = 512 * 1024
      MAX_CONTENT_HTML_BYTES = 48 * 1024
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15
      CONNECTION_ID_PATTERN = /\Adbc_[0-9a-f]{24}\z/
      RESOURCE_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

      class Error < StandardError; end

      def initialize
        @origin = parse_origin(SiteSetting.discussion_bridge_publisher_receiver_url)
        @connection_id = SiteSetting.discussion_bridge_publisher_connection_id.to_s
        @secret = read_secret
        raise Error, "invalid_connection_id" unless CONNECTION_ID_PATTERN.match?(@connection_id)
      end

      def resolve(topic:, correlation_id:)
        content_html = topic.first_post&.cooked.to_s
        raise Error, "invalid_published_content" if content_html.blank? || content_html.bytesize > MAX_CONTENT_HTML_BYTES

        request_json(
          :post,
          "/discussion-bridge/v1/bridge-records/resolve.json",
          body: {
            bridge_record: {
              direction: "to_discourse",
              external_id: TopicIdentity.external_id(topic),
              canonical_url: TopicIdentity.canonical_url(topic),
              title: topic.title,
              content_html: content_html,
              published: true,
              lane: SiteSetting.discussion_bridge_publisher_lane,
              adapter_id: DiscussionBridge::PLUGIN_NAME,
              adapter_version: DiscussionBridge::VERSION,
              correlation_id: correlation_id,
              visibility: "unlisted",
            },
          },
        )
      end

      def fetch(resource_id)
        raise Error, "invalid_resource_id" unless RESOURCE_ID_PATTERN.match?(resource_id.to_s)

        request_json(:get, "/discussion-bridge/v1/bridge-records/#{resource_id}.json")
      end

      private

      def read_secret
        path = ENV["DISCUSSION_BRIDGE_PUBLISHER_SECRET_FILE"].to_s
        raise Error, "missing_secret_file" if path.empty?

        stat = File.stat(path)
        raise Error, "invalid_secret_file" unless stat.file? && stat.size.between?(16, 1024) && (stat.mode & 0o007).zero?

        value = File.binread(path).strip
        raise Error, "invalid_secret" if value.bytesize < 16 || value.bytesize > 1024

        value
      rescue Errno::ENOENT, Errno::EACCES
        raise Error, "unreadable_secret_file"
      end

      def parse_origin(value)
        uri = URI.parse(value.to_s)
        valid = uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? &&
          (uri.path.blank? || uri.path == "/") && uri.query.nil? && uri.fragment.nil?
        raise Error, "invalid_receiver_origin" unless valid

        uri.path = ""
        uri
      rescue URI::InvalidURIError
        raise Error, "invalid_receiver_origin"
      end

      def request_json(method, path, body: nil)
        uri = @origin.dup
        uri.path = path
        request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        request["X-DiscussionBridge-Connection"] = @connection_id
        request["X-DiscussionBridge-Secret"] = @secret
        if body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        end

        response_body = +""
        response = nil
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT,
        ) do |http|
          http.request(request) do |streamed_response|
            response = streamed_response
            streamed_response.read_body do |chunk|
              response_body << chunk
              raise Error, "response_too_large" if response_body.bytesize > MAX_RESPONSE_BYTES
            end
          end
        end

        raise Error, "redirect_rejected" if response.is_a?(Net::HTTPRedirection)
        raise Error, "http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)
        content_type = response["Content-Type"].to_s.split(";", 2).first.to_s.downcase
        raise Error, "invalid_content_type" unless content_type == "application/json"

        JSON.parse(response_body)
      rescue JSON::ParserError
        raise Error, "invalid_json"
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError
        raise Error, "network_failure"
      end
    end
  end
end
