import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discussion-bridge-publication-summary-model",
  before: "inject-discourse-objects",

  initialize() {
    withPluginApi((api) => {
      api.addModelField("topic", "discussion_bridge_publication_summary", {
        type: "object",
      });
    });
  },
};
