# frozen_string_literal: true

require_relative "cms_protocol"

module DiscussionBridge
  # Validate this plugin's CMS transport before native request logging
  # asks Rails to parse JSON. Other routes pass through the original stack.
  class CmsJsonTransportGuard
    def initialize(app)
      @app = app
    end

    def call(env)
      path = env.fetch("PATH_INFO", "")
      cms_api =
        path.match?(
          %r{\A/discussion-bridge/v2/(?:work/|sources(?:/|\.json|\z)|mappings(?:/|\.json|\z)|catalog(?:/|\.json|\z)|connection(?:\.json|\z)|policy(?:\.json|\z))},
        ) && %w[POST GET].include?(env["REQUEST_METHOD"])
      native_configuration =
        path.match?(
          %r{\A/discussion-bridge/admin/content-connections/[1-9][0-9]*/cms-configuration(?:\.json)?\z},
        ) && %w[PUT GET].include?(env["REQUEST_METHOD"])
      return @app.call(env) unless cms_api || native_configuration

      encoding = env["HTTP_CONTENT_ENCODING"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      input = env.fetch("rack.input")
      body = input.read(65_537).to_s
      input.rewind
      if env["REQUEST_METHOD"] == "GET"
        CmsProtocol.reject!("invalid_field") unless body.empty?
      else
        media = env["CONTENT_TYPE"].to_s
        unless media.match?(%r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\z}i)
          CmsProtocol.reject!("unsupported_media_type")
        end
        # Negative-zero semantics belong after authentication. Preserve the raw
        # body so the controller can perform that typed check in order.
        CmsProtocol.parse_json(body, reject_negative_zero: false)
      end
      validate_query_syntax!(env.fetch("QUERY_STRING", ""))
      @app.call(env)
    rescue CmsProtocol::Error => error
      definition = CmsProtocol::ERRORS.fetch(error.code)
      body =
        JSON.generate(
          outcome: "rejected",
          code: error.code,
          retryable: definition.fetch("retryable"),
          retry_after_seconds: nil,
          correlation_id: nil,
          core_fallback: false,
        )
      [
        definition.fetch("http"),
        {
          "content-type" => "application/json; charset=utf-8",
          "content-length" => body.bytesize.to_s,
          "cache-control" => "no-store",
          "x-content-type-options" => "nosniff",
        },
        [body],
      ]
    end

    private

    def validate_query_syntax!(query)
      return if query.empty?
      keys = []
      query
        .split("&", -1)
        .each do |member|
          CmsProtocol.reject!("invalid_field") if member.empty?
          key, value = member.split("=", 2)
          decoded =
            [key, value || ""].map do |encoded|
              CmsProtocol.reject!("invalid_field") if encoded.match?(/%(?![0-9a-fA-F]{2})/)
              text =
                URI::DEFAULT_PARSER.unescape(encoded.tr("+", " ")).force_encoding(Encoding::UTF_8)
              CmsProtocol.reject!("invalid_field") unless text.valid_encoding?
              text
            end
          CmsProtocol.reject!("invalid_field") if keys.include?(decoded.first)
          keys << decoded.first
        end
    end
  end
end
