# frozen_string_literal: true

module DiscussionBridge
  class ContentConnectionAuthenticator
    def self.call(request)
      public_id = request.headers["X-DiscussionBridge-Connection"]
      secret = request.headers["X-DiscussionBridge-Secret"]
      return unless public_id.is_a?(String) && public_id.bytesize <= 64

      connection = DiscussionBridgeContentConnection.find_by(public_id: public_id, enabled: true)
      return unless connection&.authenticate_secret?(secret)

      connection.update_columns(last_seen_at: Time.zone.now, updated_at: Time.zone.now)
      connection
    end
  end
end
