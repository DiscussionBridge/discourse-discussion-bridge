import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
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
  @tracked migrationConnectionId = null;
  @tracked newPublicationUrl = "";
  @tracked notice = "";

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
    this.notice = "";
    try {
      this.status = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/connections/${item.connection.id}/policy.json`,
        {
          type: "PUT",
          data: { publication_policy: { decision } },
        }
      );
      this.notice = i18n("discussion_bridge.topic_status.policy_saved");
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.workingConnectionId = null;
    }
  }

  @action
  async syncNow(item) {
    this.workingConnectionId = item.connection.id;
    this.notice = "";
    try {
      this.status = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/connections/${item.connection.id}/reconcile.json`,
        { type: "POST" }
      );
      this.notice = i18n("discussion_bridge.topic_status.reconciled");
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.workingConnectionId = null;
    }
  }

  @action
  beginUrlMigration(item) {
    this.migrationConnectionId = item.connection.id;
    this.newPublicationUrl = "";
    this.notice = "";
  }

  @action
  cancelUrlMigration() {
    this.migrationConnectionId = null;
    this.newPublicationUrl = "";
  }

  @action
  updateNewPublicationUrl(event) {
    this.newPublicationUrl = event.target.value;
  }

  @action
  async migratePublicationUrl(item, event) {
    event.preventDefault();
    this.workingConnectionId = item.connection.id;
    this.notice = "";
    try {
      await ajax(
        `/discussion-bridge/v1/publisher/publications/${item.publication.resource_id}/migrate-url.json`,
        {
          type: "PUT",
          data: {
            migration: {
              old_url: item.publication.canonical_url,
              new_url: this.newPublicationUrl,
            },
          },
        }
      );
      this.cancelUrlMigration();
      await this.loadStatus();
      this.notice = i18n("discussion_bridge.topic_status.url_migrated");
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.workingConnectionId = null;
    }
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  connectionWorking(item) {
    return this.workingConnectionId === item.connection.id;
  }

  publishDisabled(item) {
    return (
      this.connectionWorking(item) ||
      !item.effective.publish_allowed ||
      item.override.decision === "publish"
    );
  }

  stopDisabled(item) {
    return this.connectionWorking(item) || item.override.decision === "exclude";
  }

  rulesDisabled(item) {
    return this.connectionWorking(item) || item.override.decision === "inherit";
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
          <header class="discussion-bridge-topic-status__topic">
            <strong>{{this.status.title}}</strong>
            <span>{{i18n
                "discussion_bridge.topic_status.topic_id"
                id=this.status.topic_id
              }}</span>
          </header>

          {{#if this.notice}}
            <p class="discussion-bridge-topic-status__notice" role="status">
              {{this.notice}}
            </p>
          {{/if}}

          <div class="discussion-bridge-topic-status__connections">
            {{#each this.status.connections as |item|}}
              <article class="discussion-bridge-topic-status__connection">
                <header>
                  <div>
                    <h3>{{item.connection.name}}</h3>
                    <span>{{this.displayToken item.connection.platform}}</span>
                  </div>
                  <strong
                    class="discussion-bridge-topic-status__state"
                    data-state={{if
                      item.work
                      item.work.state
                      (if item.effective.eligible "eligible" "excluded")
                    }}
                  >
                    {{#if item.work}}
                      {{this.displayToken item.work.state}}
                    {{else if item.effective.eligible}}
                      {{i18n "discussion_bridge.topic_status.eligible"}}
                    {{else}}
                      {{i18n "discussion_bridge.topic_status.not_published"}}
                    {{/if}}
                  </strong>
                </header>

                <dl>
                  <div>
                    <dt>{{i18n
                        "discussion_bridge.topic_status.connection_rule"
                      }}</dt>
                    <dd>{{#if item.rule.eligible}}
                        {{i18n
                          "discussion_bridge.topic_status.included_by_rules"
                        }}
                      {{else}}
                        {{this.displayToken item.rule.reason}}
                      {{/if}}</dd>
                  </div>
                  <div>
                    <dt>{{i18n
                        "discussion_bridge.topic_status.operator_override"
                      }}</dt>
                    <dd>{{this.displayToken item.override.decision}}{{#if
                        item.override.set_by
                      }} · {{item.override.set_by}}{{/if}}</dd>
                  </div>
                  <div>
                    <dt>{{i18n
                        "discussion_bridge.topic_status.effective_policy"
                      }}</dt>
                    <dd>{{#if item.effective.eligible}}
                        {{i18n "discussion_bridge.topic_status.publish"}}
                      {{else}}
                        {{i18n
                          "discussion_bridge.topic_status.stop_publishing"
                        }}
                        ·
                        {{this.displayToken item.effective.reason}}
                      {{/if}}</dd>
                  </div>
                  <div>
                    <dt>{{i18n
                        "discussion_bridge.topic_status.publication"
                      }}</dt>
                    <dd>{{#if item.publication}}
                        <a href={{item.publication.canonical_url}}>
                          {{item.publication.canonical_url}}
                        </a>
                      {{else}}
                        {{i18n "discussion_bridge.topic_status.no_publication"}}
                      {{/if}}</dd>
                  </div>
                </dl>

                <div class="discussion-bridge-topic-status__actions">
                  <DButton
                    @label="discussion_bridge.topic_status.publish"
                    @action={{fn this.setPolicy item "publish"}}
                    @disabled={{this.publishDisabled item}}
                    class="btn-primary"
                  />
                  <DButton
                    @label="discussion_bridge.topic_status.stop_publishing"
                    @action={{fn this.setPolicy item "exclude"}}
                    @disabled={{this.stopDisabled item}}
                  />
                  <DButton
                    @label="discussion_bridge.topic_status.use_connection_rules"
                    @action={{fn this.setPolicy item "inherit"}}
                    @disabled={{this.rulesDisabled item}}
                  />
                  <DButton
                    @label="discussion_bridge.topic_status.sync_now"
                    @action={{fn this.syncNow item}}
                    @disabled={{this.connectionWorking item}}
                  />
                  {{#if item.publication.native_materialization}}
                    <DButton
                      @label="discussion_bridge.topic_status.change_url"
                      @action={{fn this.beginUrlMigration item}}
                      @disabled={{this.connectionWorking item}}
                    />
                  {{/if}}
                </div>

                {{#if (eq this.migrationConnectionId item.connection.id)}}
                  <form
                    class="discussion-bridge-topic-status__migration"
                    {{on "submit" (fn this.migratePublicationUrl item)}}
                  >
                    <h4>{{i18n
                        "discussion_bridge.topic_status.change_url"
                      }}</h4>
                    <p>{{i18n
                        "discussion_bridge.topic_status.change_url_description"
                      }}</p>
                    <p><strong>{{i18n
                          "discussion_bridge.topic_status.current_url"
                        }}</strong>
                      <code>{{item.publication.canonical_url}}</code></p>
                    <label>{{i18n "discussion_bridge.topic_status.new_url"}}
                      <input
                        required
                        type="url"
                        value={{this.newPublicationUrl}}
                        {{on "input" this.updateNewPublicationUrl}}
                      />
                    </label>
                    <DButton
                      @type="submit"
                      @label="discussion_bridge.topic_status.verify_and_change_url"
                      @disabled={{this.connectionWorking item}}
                      class="btn-primary"
                    />
                    <DButton
                      @label="discussion_bridge.admin.cancel"
                      @action={{this.cancelUrlMigration}}
                    />
                  </form>
                {{/if}}
              </article>
            {{else}}
              <p>{{i18n "discussion_bridge.topic_status.no_connections"}}</p>
            {{/each}}
          </div>
        {{/if}}
      </:body>
      <:footer>
        <DModalCancel @close={{@closeModal}} />
      </:footer>
    </DModal>
  </template>
}
