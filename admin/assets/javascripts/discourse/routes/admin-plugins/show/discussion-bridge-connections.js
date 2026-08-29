import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeConnectionsRoute extends Route {
  model() {
    return ajax("/discussion-bridge/admin/content-connections.json");
  }
}
