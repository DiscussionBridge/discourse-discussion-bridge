# frozen_string_literal: true

module DiscussionBridge
  class CmsSourceMovesController < CmsRecordsController
    MUTATION_TYPES = { "prepare" => "SourceUrlMovePrepare", "finalize" => "SourceUrlMoveFinalize", "abort" => "SourceUrlMoveAbort" }.freeze

    def prepare
      respond(move_store.prepare(params[:resource_id], @input))
    end

    def finalize
      respond(move_store.finalize(params[:resource_id], params[:move_id], @input))
    end

    def abort
      respond(move_store.abort(params[:resource_id], params[:move_id], @input))
    end

    def url_history
      respond(record_read_store.url_history(params[:resource_id], @mapping_query))
    end

    private

    def move_store
      @move_store ||= CmsSourceMoveStore.new(@content_connection, authenticated_secret_digest: @authenticated_secret_digest)
    end

    def validate_typed_input
      return CmsProtocol.validate!("CursorQuery", @mapping_query) if request.get?
      validate_no_query!
      @input = CmsProtocol.parse_json(@raw_body, type: MUTATION_TYPES.fetch(action_name))
    end
  end
end
