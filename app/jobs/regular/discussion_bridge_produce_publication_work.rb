# frozen_string_literal: true

module Jobs
  class DiscussionBridgeProducePublicationWork < ::Jobs::Base
    def execute(args)
      id = args[:production_id]
      raise ArgumentError, "invalid publication continuation" unless id.is_a?(Integer) && id.positive?
      return unless ::DiscussionBridge::SourceRevocationProducer.enabled?
      ::DiscussionBridge::PublicationWorkProducer.resume!(id)
    end
  end
end
