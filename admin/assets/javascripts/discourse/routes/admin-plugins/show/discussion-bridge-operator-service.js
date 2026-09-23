import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeOperatorServiceRoute extends Route {
  model() {
    return ajax("/discussion-bridge/admin/operator-service.json");
  }
}

