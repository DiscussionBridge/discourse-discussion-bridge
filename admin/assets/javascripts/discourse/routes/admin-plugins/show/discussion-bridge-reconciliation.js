import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeReconciliationRoute extends Route {
  queryParams = {
    query: { refreshModel: true },
    severity: { refreshModel: true },
    page: { refreshModel: true },
  };

  model(params) {
    return ajax("/discussion-bridge/admin/reconciliation.json", {
      data: {
        query: params.query,
        severity: params.severity,
        page: params.page,
      },
    });
  }
}
