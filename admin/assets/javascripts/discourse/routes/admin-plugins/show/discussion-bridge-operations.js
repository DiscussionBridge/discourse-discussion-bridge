import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeOperationsRoute extends Route {
  queryParams = {
    kind: { refreshModel: true },
    query: { refreshModel: true },
    filter: { refreshModel: true },
    page: { refreshModel: true },
  };

  model(params) {
    return ajax("/discussion-bridge/admin/operations.json", {
      data: {
        kind: params.kind || "mappings",
        query: params.query || "",
        filter: params.filter || "",
        page: params.page || 1,
      },
    });
  }
}
