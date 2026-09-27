# frozen_string_literal: true

module DiscussionBridge
  class AdapterConnectionController < AdapterController
    def show
      response.set_header("Cache-Control", "private, no-store")
      render_protocol_json(ConnectionCapability.payload(@content_connection))
    end
  end
end
