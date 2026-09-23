import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeOperatorRoute extends Route {
  model() {
    return ajax("/discussion-bridge/admin/publishing.json");
  }
}

