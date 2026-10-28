import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgePublishingRoute extends Route {
  model() {
    return ajax("/admin/publishing.json");
  }
}
