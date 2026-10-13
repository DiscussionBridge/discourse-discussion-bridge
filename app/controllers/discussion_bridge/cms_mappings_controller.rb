# frozen_string_literal: true

module DiscussionBridge
  class CmsMappingsController < CmsWorkController
    MUTATION_TYPES = { "prepare" => "MappingPrepare", "adopt" => "MappingAdopt" }.freeze

    def prepare
      respond(mapping_service.prepare(@input))
    end

    def adopt
      respond(mapping_service.adopt(@input))
    end

    def show
      CmsProtocol.validate!("UUID", params[:mapping_id])
      respond(mapping_service.show(params[:mapping_id]))
    end

    def index
      respond(read_store.inventory(@mapping_query))
    end

    def url_history
      CmsProtocol.validate!("UUID", params[:mapping_id])
      respond(read_store.url_history(params[:mapping_id], @mapping_query))
    end

    private

    def mapping_service
      @mapping_service ||= CmsMappingService.new(
        @content_connection,
        authenticated_secret_digest: @authenticated_secret_digest
      )
    end

    def read_store
      @read_store ||= CmsMappingReadStore.new(
        @content_connection,
        authenticated_secret_digest: @authenticated_secret_digest
      )
    end

    def validate_transport
      return super unless request.get?
      encoding = request.headers["Content-Encoding"]
      CmsProtocol.reject!("unsupported_media_type") unless encoding.nil? || encoding == "identity"
      body = request.body.read(65_537).to_s
      request.body.rewind
      CmsProtocol.reject!("invalid_field") unless body.empty?
      @mapping_query = {}
      unless request.query_string.empty?
        request.query_string.split("&", -1).each do |member|
          CmsProtocol.reject!("invalid_field") if member.empty?
          key, value = member.split("=", 2)
          decoded = [key, value || ""].map do |encoded|
            CmsProtocol.reject!("invalid_field") if encoded.match?(/%(?![0-9a-fA-F]{2})/)
            text = URI::DEFAULT_PARSER.unescape(encoded.tr("+", " ")).force_encoding(Encoding::UTF_8)
            CmsProtocol.reject!("invalid_field") unless text.valid_encoding?
            text
          end
          CmsProtocol.reject!("invalid_field") if @mapping_query.key?(decoded.first)
          @mapping_query[decoded.first] = decoded.last
        end
      end
    end

    def validate_typed_input
      if request.get?
        if action_name == "show"
          CmsProtocol.reject!("unknown_field") unless @mapping_query.empty?
        else
          CmsProtocol.validate!("CursorQuery", @mapping_query)
        end
      else
        validate_no_query!
        @input = CmsProtocol.parse_json(@raw_body, type: MUTATION_TYPES.fetch(action_name))
      end
    end
  end
end
