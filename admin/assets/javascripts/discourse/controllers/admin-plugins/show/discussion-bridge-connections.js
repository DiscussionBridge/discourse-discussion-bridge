import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";

export default class DiscussionBridgeConnectionsController extends Controller {
  @tracked return_to = "";
  queryParams = ["return_to"];
}
