import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgePublishing extends Component {
  @service router;

  @tracked topicId = "";
  @tracked connectionId = "";
  @tracked externalId = "";
  @tracked canonicalUrl = "";
  @tracked lane = "";
  @tracked nativeMaterialization = false;
  @tracked notice = "";
  @tracked createdRecord = null;
  @tracked working = false;

  @action
  updateTopicId(event) { this.topicId = event.target.value; }

  @action
  updateConnectionId(event) {
    this.connectionId = event.target.value;
    const connection = this.selectedConnection;
    this.lane = connection?.allowed_lanes?.length === 1
      ? connection.allowed_lanes[0]
      : "";
  }

  @action
  updateLane(event) { this.lane = event.target.value; }

  @action
  updateExternalId(event) { this.externalId = event.target.value; }

  @action
  updateCanonicalUrl(event) { this.canonicalUrl = event.target.value; }

  @action
  updateNativeMaterialization(event) { this.nativeMaterialization = event.target.checked; }

  get selectedConnection() {
    return this.args.model.connections.find(
      (connection) => String(connection.id) === String(this.connectionId)
    );
  }

  get selectedLanes() {
    return this.selectedConnection?.allowed_lanes || [];
  }

  @action
  async publishTopic(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      const result = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/publish.json`,
        {
          type: "POST",
          data: {
            publication: {
              content_connection_id: this.connectionId,
              external_id: this.externalId,
              canonical_url: this.canonicalUrl,
              lane: this.lane || null,
              native_materialization: this.nativeMaterialization,
            },
          },
        }
      );
      this.createdRecord = result;
      this.notice = i18n(
        result.outcome === "created"
          ? "discussion_bridge.admin.publisher_created"
          : "discussion_bridge.admin.publisher_resolved"
      );
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  displayToken(value) { return value?.replaceAll("_", " ") || "—"; }

  <template>
    <section class="discussion-bridge-publishing">
      <header class="discussion-bridge-publishing__hero">
        <div><span aria-hidden="true">DB</span><div><h2>{{i18n "discussion_bridge.admin.publishing_nav"}}</h2><p>{{i18n "discussion_bridge.admin.publishing_description"}}</p></div></div>
        <strong data-ready={{@model.product.ready}}>{{if @model.product.ready (i18n "discussion_bridge.admin.publisher_ready") (i18n "discussion_bridge.admin.needs_attention")}}</strong>
      </header>

      <DPageSubheader @titleLabel={{i18n "discussion_bridge.admin.publishing_nav"}} @descriptionLabel={{@model.product.version}} />

      <div class="discussion-bridge-publishing__metrics">
        <article><span>{{i18n "discussion_bridge.admin.publisher_published_topics"}}</span><strong>{{@model.metrics.published_topics}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_presentations"}}</span><strong>{{@model.metrics.presentations}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_connected_platforms"}}</span><strong>{{@model.metrics.connected_platforms}}</strong></article>
      </div>

      {{#if @model.product.blockers.length}}
        <section class="discussion-bridge-publishing__connection">
          <h3>{{i18n "discussion_bridge.admin.publisher_configuration_blockers"}}</h3>
          <ul>{{#each @model.product.blockers as |blocker|}}<li><code>{{blocker}}</code></li>{{/each}}</ul>
        </section>
      {{/if}}

      {{#if this.notice}}<p class="discussion-bridge-publishing__notice" role="status">{{this.notice}}{{#if this.createdRecord}} · <a href={{this.createdRecord.topic_url}}>Open topic {{this.createdRecord.topic_id}}</a>{{/if}}</p>{{/if}}

      <div class="discussion-bridge-publishing__actions">
        <form {{on "submit" this.publishTopic}}>
          <h3>{{i18n "discussion_bridge.admin.publisher_publish_title"}}</h3>
          <p>{{i18n "discussion_bridge.admin.publisher_publish_description"}}</p>
          <label>{{i18n "discussion_bridge.admin.publisher_local_topic_id"}}<input required min="1" type="number" value={{this.topicId}} {{on "input" this.updateTopicId}} /></label>
          <label>{{i18n "discussion_bridge.admin.publisher_connection"}}
            <select required {{on "change" this.updateConnectionId}}>
              <option value="">—</option>
              {{#each @model.connections as |connection|}}<option value={{connection.id}} selected={{eq connection.id this.connectionId}}>{{connection.name}} · {{this.displayToken connection.platform}}</option>{{/each}}
            </select>
          </label>
          {{#if this.selectedLanes.length}}
            <label>{{i18n "discussion_bridge.admin.lane"}}
              <select required {{on "change" this.updateLane}}>
                <option value="">—</option>
                {{#each this.selectedLanes as |lane|}}<option value={{lane}} selected={{eq lane this.lane}}>{{lane}}</option>{{/each}}
              </select>
            </label>
          {{/if}}
          <label>{{i18n "discussion_bridge.admin.external_id"}}<input required value={{this.externalId}} {{on "input" this.updateExternalId}} /></label>
          <label>{{i18n "discussion_bridge.admin.presentation_url"}}<input required type="url" value={{this.canonicalUrl}} {{on "input" this.updateCanonicalUrl}} /></label>
          <label class="discussion-bridge-publishing__checkbox"><input type="checkbox" checked={{this.nativeMaterialization}} {{on "change" this.updateNativeMaterialization}} /> {{i18n "discussion_bridge.admin.publisher_native_materialization"}}</label>
          <DButton @type="submit" @label="discussion_bridge.admin.publisher_publish" @disabled={{this.working}} class="btn-primary" />
        </form>
      </div>

      <section class="discussion-bridge-publishing__recent">
        <h3>{{i18n "discussion_bridge.admin.publisher_recent_activity"}}</h3>
        <table><thead><tr><th>{{i18n "discussion_bridge.admin.publisher_local_topic"}}</th><th>{{i18n "discussion_bridge.admin.platform"}}</th><th>{{i18n "discussion_bridge.admin.presentation"}}</th><th>{{i18n "discussion_bridge.admin.state"}}</th></tr></thead>
          <tbody>{{#each @model.recent_records as |record|}}<tr><td><a href={{record.topic_url}}>{{record.title}}</a><small><code>{{record.resource_id}}</code></small></td><td>{{this.displayToken record.platform}}</td><td><a href={{record.canonical_url}}>{{record.connection_name}}</a></td><td>{{record.state}}</td></tr>{{else}}<tr><td colspan="4">{{i18n "discussion_bridge.admin.publisher_no_activity"}}</td></tr>{{/each}}</tbody>
        </table>
      </section>
    </section>
  </template>
}
