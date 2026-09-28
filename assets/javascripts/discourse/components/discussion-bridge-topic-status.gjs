import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DModalCancel from "discourse/ui-kit/d-modal-cancel";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeTopicStatus extends Component {
  @tracked status = null;
  @tracked loading = true;
  @tracked workingConnectionId = null;

  constructor() {
    super(...arguments);
    void this.loadStatus();
  }

  get topicId() {
    return this.args.model.topic.id;
  }

  @action
  async loadStatus() {
    this.loading = true;
    try {
      this.status = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/status.json`
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  @action
  async setPolicy(item, decision) {
    this.workingConnectionId = item.connection.id;
    try {
      this.status = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/connections/${item.connection.id}/policy.json`,
        {
          type: "PUT",
          data: { publication_policy: { decision } },
        }
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.workingConnectionId = null;
    }
  }

  @action
  async reconcile(item) {
    this.workingConnectionId = item.connection.id;
    try {
      this.status = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/connections/${item.connection.id}/reconcile.json`,
        { type: "POST" }
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.workingConnectionId = null;
    }
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  <template>
    <DModal
      @closeModal={{@closeModal}}
      @title={{i18n "discussion_bridge.topic_status.title"}}
      class="discussion-bridge-topic-status"
    >
      <:body>
        {{#if this.loading}}
          <p>{{i18n "discussion_bridge.topic_status.loading"}}</p>
        {{else if this.status}}
          <section class="discussion-bridge-topic-status__discussion">
            <h3>{{i18n "discussion_bridge.topic_status.discussion"}}</h3>
            <p>{{i18n
                "discussion_bridge.topic_status.discussion_detail"
                replies=this.status.discussion.reply_count
                closed=this.status.discussion.closed
                archived=this.status.discussion.archived
              }}</p>
          </section>
          {{#each this.status.publications as |item|}}
            <article class="discussion-bridge-topic-status__publication">
              <header>
                <h3>{{item.connection.name}}</h3>
                <strong>{{this.displayToken
                    item.publication.delivery.state
                  }}</strong>
              </header>
              <p><a href={{item.publication.canonical_url}}>
                  {{item.publication.canonical_url}}
                </a></p>
              <p>{{i18n "discussion_bridge.topic_status.publication_detail"}}
                {{this.displayToken item.override.decision}}
                ·
                {{this.displayToken item.publication.presentation_mode}}</p>
              <div class="discussion-bridge-topic-status__actions">
                <DButton
                  @label="discussion_bridge.topic_status.include"
                  @action={{fn this.setPolicy item "include"}}
                  @disabled={{eq this.workingConnectionId item.connection.id}}
                  class="btn-primary"
                />
                <DButton
                  @label="discussion_bridge.topic_status.exclude"
                  @action={{fn this.setPolicy item "exclude"}}
                  @disabled={{eq this.workingConnectionId item.connection.id}}
                />
                <DButton
                  @label="discussion_bridge.topic_status.inherit"
                  @action={{fn this.setPolicy item "inherit"}}
                  @disabled={{eq this.workingConnectionId item.connection.id}}
                />
                <DButton
                  @label="discussion_bridge.topic_status.reconcile"
                  @action={{fn this.reconcile item}}
                  @disabled={{eq this.workingConnectionId item.connection.id}}
                />
              </div>
            </article>
          {{else}}
            <p>{{i18n "discussion_bridge.topic_status.no_publications"}}</p>
          {{/each}}
        {{/if}}
      </:body>
      <:footer><DModalCancel @close={{@closeModal}} /></:footer>
    </DModal>
  </template>
}
