import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DiscussionBridgeTopicStatus from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-topic-status";
import DButton from "discourse/ui-kit/d-button";

export default class DiscussionBridgeOperatorTopicControl extends Component {
  @service modal;

  get topic() {
    return this.args.outletArgs?.topic;
  }

  @action
  openStatus() {
    if (this.topic) {
      this.modal.show(DiscussionBridgeTopicStatus, {
        model: { topic: this.topic },
      });
    }
  }

  <template>
    {{#if this.topic}}
      <DButton
        @icon="bridge"
        @label="discussion_bridge.topic_status.menu_label"
        @action={{this.openStatus}}
        class="discussion-bridge-operator-topic-control"
      />
    {{/if}}
  </template>
}

