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
      @history_query = {}
      request
        .query_string
        .split("&", -1)
        .each do |member|
          CmsProtocol.reject!("invalid_field") if member.empty?
          key, value = member.split("=", 2)
          CmsProtocol.reject!("invalid_field") unless value
          pair = URI.decode_www_form("#{key}=#{value}", Encoding::UTF_8).first
          CmsProtocol.reject!("invalid_field") unless pair
          @history_query[pair.first] = pair.last
        end
    end

    def validate_typed_input
      CmsProtocol.reject!("invalid_field") unless request.get?
      CmsProtocol.validate!("PolicyHistoryQuery", @history_query)
    end
  end
end
