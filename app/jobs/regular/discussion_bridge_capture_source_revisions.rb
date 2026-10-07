# frozen_string_literal: true

module Jobs
  class DiscussionBridgeCaptureSourceRevisions < ::Jobs::Base
    def execute(args)
      return unless ::DiscussionBridge::SourceRevocationProducer.enabled?
      selector = args.stringify_keys.slice(*::DiscussionBridge::SourceRevocationProducer::SELECTORS)
      ::DiscussionBridge::SourceRevocationProducer.validate_selector!(selector)
      cut, position = args.values_at(:cut, :position)
      unless cut.is_a?(Integer) && position.is_a?(Integer) && cut.positive? && position.between?(0, cut)
        raise ArgumentError, "invalid source update continuation"
      end
      scope = ::DiscussionBridge::SourceRevocationProducer.bindings(selector).where("discussion_bridge_content_bindings.id > ? AND discussion_bridge_content_bindings.id <= ?", position, cut)
      ids = scope.order(:id).limit(::DiscussionBridge::SourceRevisionProducer::BATCH_SIZE).pluck(:id)
      ids.each { |id| ::DiscussionBridge::SourceRevisionProducer.call(binding_id: id) }
      if ids.any? && ::DiscussionBridge::SourceRevocationProducer.bindings(selector)
          .where("discussion_bridge_content_bindings.id > ? AND discussion_bridge_content_bindings.id <= ?", ids.last, cut).exists?
        Jobs.enqueue(:discussion_bridge_capture_source_revisions, **selector.symbolize_keys, cut: cut, position: ids.last)
      end
    end
  end
end
