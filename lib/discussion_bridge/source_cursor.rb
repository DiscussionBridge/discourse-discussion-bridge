# frozen_string_literal: true

module DiscussionBridge
  class SourceCursor
    PURPOSE = "discussion-bridge-source-publication-cursor"

    def self.issue(kind:, payload:)
      token = verifier.generate(payload.merge("kind" => kind), purpose: PURPOSE)
      raise AdapterRequestBoundary::Error, "internal_error" if
        token.bytesize > SourcePublicationProtocol::MAXIMUM_CURSOR_BYTES

      token
    end

    def self.read(token, kind:)
      raise AdapterRequestBoundary::Error, "malformed_value" unless
        token.is_a?(String) && token.present? &&
          token.bytesize <= SourcePublicationProtocol::MAXIMUM_CURSOR_BYTES

      payload = verifier.verified(token, purpose: PURPOSE)
      raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch" unless
        payload.is_a?(Hash) && payload["kind"] == kind

      payload.except("kind")
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      raise AdapterRequestBoundary::Error, "cursor_snapshot_mismatch"
    end

    def self.verifier
      Rails.application.message_verifier(:discussion_bridge_source_publication_cursor)
    end
    private_class_method :verifier
  end
end
