# frozen_string_literal: true

module DiscussionBridge
  module SiteSettingLabelFormatterExtension
    SETTING_PREFIX = "discussion_bridge_"

    def humanized_name(setting)
      label = super
      return label unless setting.to_s.start_with?(SETTING_PREFIX)

      label.sub(/\ADiscussion bridge\b/, "DiscussionBridge")
    end
  end
end
