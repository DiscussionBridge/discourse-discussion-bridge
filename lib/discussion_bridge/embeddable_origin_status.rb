# frozen_string_literal: true

module DiscussionBridge
  class EmbeddableOriginStatus
    def self.for_connection(connection)
      connection.allowed_origins.map { |origin| for_origin(origin) }
    end

    def self.for_origin(origin)
      { origin: origin, embeddable: EmbeddableHost.url_allowed?(origin) }
    end
  end
end
