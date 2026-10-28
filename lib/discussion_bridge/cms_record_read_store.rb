# frozen_string_literal: true

module DiscussionBridge
  class CmsRecordReadStore < CmsMappingReadStore
    def inventory(query = {})
      page("record_inventory", "", query) do |snapshot|
        store = record_store
        count = 0
        store.scoped_bindings.find_each(batch_size: PAGE_ITEMS) do |binding|
          next unless store.binding_available?(binding)
          append!(snapshot, count, store.projection(binding))
          count += 1
        end
        count
      end
    end

    def url_history(resource_id, query = {})
      CmsProtocol.validate!("UUID", resource_id)
      page("source_url_history", resource_id, query) do |snapshot|
        binding = history_binding!(resource_id)
        count = 0
        DiscussionBridgeCmsUrlHistoryEntry.where(content_binding_id: binding.id).find_each(batch_size: PAGE_ITEMS) do |entry|
          append!(snapshot, count, { "url" => entry.url, "retired_at" => CmsProtocol.instant(entry.retired_at), "move_id" => entry.move_id })
          count += 1
        end
        count
      end
    end

    private

    def history_binding!(resource_id)
      binding = record_store.owned_binding!(resource_id)
      CmsProtocol.reject!("scope_denied") unless binding.bridge_record.direction == "to_discourse"
      binding
    end

    def record_store
      CmsRecordStore.new(@connection, clock: @clock, authenticated_secret_digest: @authenticated_secret_digest)
    end

    def current_configuration!
      CmsProtocol.reject!("scope_denied") unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled
      CmsConfiguration.current!(@connection, required_direction: nil)
    end

    def verify_page_scope!(kind, resource, result, configuration)
      if kind == "source_url_history"
        history_binding!(resource)
      else
        result.body.fetch("items").each { |item| record_store.owned_binding!(item.fetch("resource_id")) }
      end
    end
  end
end

