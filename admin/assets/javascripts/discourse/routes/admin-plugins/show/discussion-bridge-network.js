import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeNetworkRoute extends Route {
  model() {
    return ajax("/discussion-bridge/admin/network.json");
  }
}
