# frozen_string_literal: true

module DiscussionBridge
  module FullInteractiveReadiness
    BLOCKERS = {
      plugin_disabled: -> { !SiteSetting.discussion_bridge_enabled },
      comments_only_full_interactive_disabled: lambda {
        !SiteSetting.discussion_bridge_comments_only_full_interactive
      },
      embed_full_app_disabled: -> { !SiteSetting.embed_full_app },
      embed_full_app_signin_flow_disabled: -> { !SiteSetting.embed_full_app_signin_flow },
    }.freeze

    def self.blockers
      BLOCKERS.filter_map { |reason, blocked| reason.to_s if blocked.call }
    end

    def self.ready?
      blockers.empty?
    end
  end
end
