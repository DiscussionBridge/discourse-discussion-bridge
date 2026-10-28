# frozen_string_literal: true

module DiscussionBridge
  class CmsPresentationMovesController < CmsMappingsController
    MUTATION_TYPES = { "prepare" => "UrlMovePrepare", "finalize" => "UrlMoveFinalize", "abort" => "UrlMoveAbort" }.freeze

    def prepare
      respond(move_store.prepare(params[:mapping_id], @input))
    end

    def finalize
      respond(move_store.finalize(params[:mapping_id], params[:move_id], @input))
    end

    def abort
      respond(move_store.abort(params[:mapping_id], params[:move_id], @input))
    end

    private

    def move_store
      @move_store ||= CmsPresentationMoveStore.new(@content_connection, authenticated_secret_digest: @authenticated_secret_digest)
    end

    def validate_typed_input
      validate_no_query!
      @input = CmsProtocol.parse_json(@raw_body, type: MUTATION_TYPES.fetch(action_name))
    end
  end
end
