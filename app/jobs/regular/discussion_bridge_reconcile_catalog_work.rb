# frozen_string_literal: true

module Jobs
  class DiscussionBridgeReconcileCatalogWork < ::Jobs::Base
    def execute(args)
      connection_id = Integer(args[:connection_id], exception: false)
      after_work_id = Integer(args[:after_work_id] || 0, exception: false)
      return unless connection_id&.positive? && after_work_id && after_work_id >= 0

      DiscussionBridge::PlatformCatalogRegistry.reconcile_removed_batch!(
        connection_id: connection_id,
        platform_profile: args[:platform_profile].to_s,
        catalog_revision: args[:catalog_revision].to_s,
        after_work_id: after_work_id,
      )
    end
  end
end
