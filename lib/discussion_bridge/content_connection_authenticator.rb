# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request)
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      return unless public_id.is_a?(String) && public_id.bytesize <= 64

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id, enabled: true)
      connection if connection&.authenticate_secret?(secret)
    end
  end
end
