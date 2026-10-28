import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeOperationsRoute extends Route {
  queryParams = {
    direction: { refreshModel: true },
    state: { refreshModel: true },
    connection_id: { refreshModel: true },
    query: { refreshModel: true },
    page: { refreshModel: true },
  };

  async model(params) {
    const [records, connections] = await Promise.all([
      ajax("/discussion-bridge/admin/bridge-records.json", {
        data: {
          direction: params.direction || "",
          state: params.state || "",
          connection_id: params.connection_id || "",
          query: params.query || "",
          page: params.page || 1,
        },
      }),
      ajax("/discussion-bridge/admin/content-connections.json"),
    ]);
    return { ...records, content_connections: connections.content_connections };
  }
}
