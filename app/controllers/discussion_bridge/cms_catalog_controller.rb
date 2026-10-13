# frozen_string_literal: true

module DiscussionBridge
  class CmsCatalogController < CmsWorkController
    CATALOG_INPUT_TYPES = {
      "begin_upload" => "CatalogBegin",
      "append_page" => "CatalogPageInput",
      "finalize" => "CatalogFinalize",
    }.freeze

    def begin_upload
      respond(catalog_store.begin_upload(@input))
    end

    def append_page
      CmsProtocol.validate!("UUID", params[:upload_id])
      respond(catalog_store.append_page(params[:upload_id], @input))
    end

    def finalize
      CmsProtocol.validate!("UUID", params[:upload_id])
      result =
        DiscussionBridgeContentConnection.transaction do
          @content_connection.lock!
          value = catalog_store.finalize(params[:upload_id], @input)
          CmsCatalogAvailabilityLifecycle.new(
            @content_connection,
            authenticated_secret_digest: @authenticated_secret_digest,
          ).apply_change!(value.change)
          value
        end
      respond(result)
    end

    def index
      respond(catalog_store.read(@catalog_query))
    end

    private

    def catalog_store
      @catalog_store ||=
        CmsCatalogStore.new(
          @content_connection,
          authenticated_secret_digest: @authenticated_secret_digest,
        )
    end

    def validate_transport
      return super unless request.get?
      encoding = request.headers["Content-Encoding"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      body = request.body.read(65_537).to_s
      request.body.rewind
      CmsProtocol.reject!("invalid_field") unless body.empty?
      @catalog_query = {}
      request
        .query_string
        .split("&", -1)
        .each do |member|
          next if member.empty? && request.query_string.empty?
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
          CmsProtocol.reject!("invalid_field") if @catalog_query.key?(decoded.first)
          @catalog_query[decoded.first] = decoded.last
        end
    end

    def validate_typed_input
      if request.get?
        CmsProtocol.validate!("CatalogReadQuery", @catalog_query)
      else
        validate_no_query!
        @input = CmsProtocol.parse_json(@raw_body, type: CATALOG_INPUT_TYPES.fetch(action_name))
      end
    end
  end
end
