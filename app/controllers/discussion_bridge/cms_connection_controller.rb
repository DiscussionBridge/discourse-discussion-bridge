# frozen_string_literal: true

module DiscussionBridge
  class CmsConnectionController < CmsWorkController
    def show
      respond(authority_store.descriptor)
    end

    def policy
      respond(authority_store.publication_policy)
    end

    private

    def authority_store
      @authority_store ||=
        CmsAuthorityStore.new(
          @content_connection,
          authenticated_secret_digest: @authenticated_secret_digest
        )
    end

    def validate_typed_input
      validate_no_query!
      CmsProtocol.reject!("invalid_field") unless request.get?
    end
  end
end
