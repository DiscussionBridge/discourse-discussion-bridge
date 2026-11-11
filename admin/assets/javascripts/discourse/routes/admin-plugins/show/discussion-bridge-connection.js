import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

const SECTIONS = ["general", "authors", "publication"];

export default class DiscussionBridgeConnectionRoute extends Route {
  @service router;

  async model({ connection_id, section }) {
    const model = await ajax(
      "/discussion-bridge/admin/content-connections.json"
    );
    const connection = model.content_connections.find(
      (entry) => String(entry.id) === String(connection_id)
    );
    return {
      ...model,
      connection,
      section,
      workspaceKey: String(connection_id) + ":" + section,
    };
  }

  afterModel({ connection, section }) {
    if (!connection || !SECTIONS.includes(section)) {
      this.router.replaceWith(
        "adminPlugins.show.discussion-bridge-connections"
      );
    }
  }
}
