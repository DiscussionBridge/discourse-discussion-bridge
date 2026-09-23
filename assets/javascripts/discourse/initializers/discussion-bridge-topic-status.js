import DiscussionBridgeTopicStatus from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-topic-status";
import DiscussionBridgePublicationBadge from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-publication-badge";
import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discussion-bridge-topic-status",

  initialize(container) {
    const currentUser = container.lookup("service:current-user");
    const siteSettings = container.lookup("service:site-settings");
    if (
      !currentUser ||
      !siteSettings.discussion_bridge_enabled ||
      !siteSettings.discussion_bridge_publisher_enabled
    ) {
      return;
    }

    withPluginApi((api) => {
      api.renderInOutlet(
        "topic-list-after-title",
        DiscussionBridgePublicationBadge
      );
      api.renderInOutlet(
        "after-topic-footer-buttons",
        DiscussionBridgePublicationBadge
      );
      if (currentUser.staff) {
        api.addTopicAdminMenuButton((topic) => ({
          action: () =>
            container
              .lookup("service:modal")
              .show(DiscussionBridgeTopicStatus, {
                model: { topic },
              }),
          icon: "bridge",
          className: "discussion-bridge-topic-status-action",
          label: "discussion_bridge.topic_status.menu_label",
          section: {
            id: "discussion-bridge",
            label: "discussion_bridge.topic_status.section_label",
          },
        }));
      }
    });
  },
};
