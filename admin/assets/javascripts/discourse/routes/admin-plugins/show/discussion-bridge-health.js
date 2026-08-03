import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeHealthRoute extends Route {
  model() {
    return ajax("/discussion-bridge/admin/health.json");
  }
}
