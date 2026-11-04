# frozen_string_literal: true

module DiscussionBridge
  class CmsPolicyHistoryController < CmsWorkController
    def index
      store =
        CmsAuthorityStore.new(
          @content_connection,
          authenticated_secret_digest: @authenticated_secret_digest
        )
      respond(store.policy_history(@history_query))
    end

    private

    def validate_transport
      if request.query_string.bytesize > 4096
        CmsProtocol.reject!("invalid_field")
      end
      super
      request
        .query_string
        .split("&", -1)
        .each do |member|
          CmsProtocol.reject!("invalid_field") if member.empty?
          CmsProtocol.reject!("invalid_field") if member.exclude?("=")
        end
      # The parent has already decoded once, without replacing invalid UTF-8,
      # and rejected duplicate decoded names. Do not decode a second time.
      @history_query = @transport_query_pairs.to_h
    end

    def validate_typed_input
      CmsProtocol.reject!("invalid_field") unless request.get?
      CmsProtocol.validate!("PolicyHistoryQuery", @history_query)
    end
  end
end
