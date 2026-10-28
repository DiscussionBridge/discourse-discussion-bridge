import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discussion-bridge-admin-nav",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    if (!currentUser?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav("discourse-discussion-bridge", [
        {
          label: "discussion_bridge.admin.health_nav",
          route: "adminPlugins.show.discussion-bridge-health",
          description: "discussion_bridge.admin.health_nav_description",
        },
        {
          label: "discussion_bridge.admin.connections_nav",
          route: "adminPlugins.show.discussion-bridge-connections",
          description: "discussion_bridge.admin.connections_nav_description",
        },
        {
          label: "discussion_bridge.admin.bridge_records_nav",
          route: "adminPlugins.show.discussion-bridge-operations",
          description: "discussion_bridge.admin.bridge_records_nav_description",
        },
        {
          label: "discussion_bridge.admin.reconciliation_nav",
          route: "adminPlugins.show.discussion-bridge-reconciliation",
          description: "discussion_bridge.admin.reconciliation_nav_description",
        },
        {
          label: "discussion_bridge.admin.publishing_nav",
          route: "adminPlugins.show.discussion-bridge-publishing",
          description: "discussion_bridge.admin.publishing_nav_description",
        },
        {
          label: "discussion_bridge.admin.settings_nav",
          route: "adminPlugins.show.settings",
          description: "discussion_bridge.admin.settings_nav_description",
        },
      ]);
    });
  },
};
