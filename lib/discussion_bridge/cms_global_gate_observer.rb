# frozen_string_literal: true

module DiscussionBridge
  # Current Core emits site_setting_changed even after plugin disable. Register
  # directly rather than Plugin::Instance#on, which filters disabled plugins.
  class CmsGlobalGateObserver
    GATES = {
      "discussion_bridge_enabled" => "plugin_disabled",
      "discussion_bridge_endpoint_enabled" => "endpoint_disabled",
      "discussion_bridge_publisher_enabled" => "publisher_disabled",
    }.freeze

    def self.register
      DiscourseEvent.on(:site_setting_changed) do |name, previous, current|
        changed(name, previous, current)
      end
    end

    def self.changed(name, previous, current)
      reason = GATES[name.to_s]
      return unless reason && previous != current
      if previous == true && current == false
        CmsSourceLifecycle.invalidate_global!(reason: reason)
      elsif previous == false && current == true
        # Current source/policy work remains responsible for admission. Its
        # retained same-intent hold cannot be erased by a wakeup or gate toggle.
        CmsNativeObserver.connection_scans
      end
    end
  end
end
