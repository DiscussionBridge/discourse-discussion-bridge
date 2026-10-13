# frozen_string_literal: true

module DiscussionBridge
  class CmsSourcesController < CmsWorkController
    def index
      respond(source_store.feed(@source_query))
    end

    def content
      CmsProtocol.validate!("OpaqueId", params[:source_id])
      CmsProtocol.validate!("Revision", params[:source_revision])
      respond(source_store.content(params[:source_id], params[:source_revision], @source_query))
    end

    private

    def source_store
      @source_store ||=
        CmsSourceStore.new(
          @content_connection,
          authenticated_secret_digest: @authenticated_secret_digest,
        )
    end

    # Syntax before authentication; schema/unknown fields after authentication.
    # Decode percent escapes once without replacement of invalid UTF8 bytes.
    def validate_transport
      CmsProtocol.reject!("invalid_field") unless request.get?
      encoding = request.headers["Content-Encoding"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      body = request.body.read(65_537).to_s
      request.body.rewind
      CmsProtocol.reject!("invalid_field") unless body.empty?
      @source_query_pairs = {}
      unless request.query_string.empty?
        request
          .query_string
          .split("&", -1)
          .each do |member|
            CmsProtocol.reject!("invalid_field") if member.empty?
            key, value = member.split("=", 2)
            decode =
              lambda do |encoded|
                CmsProtocol.reject!("invalid_field") if encoded.match?(/%(?![0-9a-fA-F]{2})/)
                decoded =
                  URI::DEFAULT_PARSER.unescape(encoded.tr("+", " ")).force_encoding(Encoding::UTF_8)
                CmsProtocol.reject!("invalid_field") unless decoded.valid_encoding?
                decoded
              end
            key = decode.call(key)
            value = decode.call(value || "")
            CmsProtocol.reject!("invalid_field") if @source_query_pairs.key?(key)
            @source_query_pairs[key] = value
          end
      end
    end

    def validate_typed_input
      type = action_name == "index" ? "SourceFeedQuery" : "ContentQuery"
      fields = CmsProtocol::SCHEMA.fetch("types").fetch(type).fetch("fields")
      @source_query =
        @source_query_pairs.to_h do |key, value|
          CmsProtocol.reject!("unknown_field") unless fields.key?(key)
          if fields.fetch(key).fetch("type") == "UInt"
            CmsProtocol.reject!("invalid_field") unless value.match?(/\A(?:0|[1-9][0-9]*)\z/)
            value = value.to_i
          end
          [key, value]
        end
      @source_query = CmsProtocol.apply_defaults(type, @source_query)
    end
  end
end
