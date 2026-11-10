import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";

export default class DiscussionBridgeConnectionsController extends Controller {
  queryParams = ["return_to"];
  @tracked return_to = "";
}
