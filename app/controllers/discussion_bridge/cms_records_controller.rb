# frozen_string_literal: true

module DiscussionBridge
  class CmsRecordsController < CmsMappingsController
    MUTATION_TYPES = { "resolve" => "ToResolve", "withdraw" => "WithdrawInput" }.freeze

    def resolve
      respond(record_store.resolve(@input))
    end

    def index
      respond(record_read_store.inventory(@mapping_query))
    end

    def show
      respond(record_store.show(params[:resource_id]))
    end

    def withdraw
      respond(record_store.withdraw(params[:resource_id], @input))
    end

    private

    def record_store
      @record_store ||= CmsRecordStore.new(@content_connection, authenticated_secret_digest: @authenticated_secret_digest)
    end

    def record_read_store
      @record_read_store ||= CmsRecordReadStore.new(@content_connection, authenticated_secret_digest: @authenticated_secret_digest)
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
        @input = CmsProtocol.parse_json(@raw_body, type: action_name == "resolve" ? nil : MUTATION_TYPES.fetch(action_name))
      end
    end
  end
end

