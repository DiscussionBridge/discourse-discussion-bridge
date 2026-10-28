# frozen_string_literal: true

module DiscussionBridge
  class CmsAttentionController < CmsWorkController
    def capability = respond(recovery.capability)
    def inspections = respond(recovery.inspections(after: @after))
    def recoveries = respond(recovery.recoveries(after: @after))
    def report = respond(recovery.report(params[:inspection_id], @input))
    def recovery_claim = respond(recovery.claim(params[:recovery_id], @input))

    private

    def recovery
      @recovery ||= CmsAttentionRecovery.new(@content_connection,
        authenticated_secret_digest: @authenticated_secret_digest)
    end

    def validate_typed_input
      if %w[inspections recoveries].include?(action_name)
        query = request.query_string
        CmsProtocol.reject!("invalid_field") if query.bytesize > 1024
        pairs = URI.decode_www_form(query, Encoding::UTF_8)
        CmsProtocol.reject!("unknown_field") unless pairs.all? { |key, _| key == "after" }
        raw = pairs.to_h.fetch("after", "0")
        CmsProtocol.reject!("invalid_field") unless raw.match?(/\A(?:0|[1-9][0-9]*)\z/) && raw.length <= 16
        @after = raw.to_i
        CmsProtocol.validate!("UInt", @after)
      else
        validate_no_query!
        type = { "report" => "AttentionInspectionReport", "recovery_claim" => "AttentionRecoveryClaim" }[action_name]
        @input = CmsProtocol.parse_json(@raw_body, type: type) if type
      end
    end
  end
end
