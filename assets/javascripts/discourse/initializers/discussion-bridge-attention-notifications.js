import { withPluginApi } from "discourse/lib/plugin-api";
import CustomNotification from "discourse/lib/notification-types/custom";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";

const MESSAGE = "discussion_bridge.attention_notice";

export default {
  name: "discussion-bridge-attention-notifications",
  initialize() {
    withPluginApi((api) => {
      api.registerNotificationTypeRenderer("custom", () => {
        return class extends CustomNotification {
          get bridgeAttention() {
            return this.notification.data?.message === MESSAGE;
          }
          get linkHref() {
            return this.bridgeAttention
              ? getURL("/admin/plugins/discourse-discussion-bridge/connections")
              : super.linkHref;
          }
          get label() {
            return this.bridgeAttention ? i18n(MESSAGE) : super.label;
          }
          get description() {
            return this.bridgeAttention ? null : super.description;
          }
          get icon() {
            return this.bridgeAttention ? "triangle-exclamation" : super.icon;
          }
        };
      });
    });
  },
};
