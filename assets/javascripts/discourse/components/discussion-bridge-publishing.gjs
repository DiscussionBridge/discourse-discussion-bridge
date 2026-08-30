import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgePublishing extends Component {
  @service router;
  @tracked topicId = "";
  @tracked resourceId = "";
  @tracked notice = "";
  @tracked importedTopic = null;
  @tracked working = false;

  @action updateTopicId(event) { this.topicId = event.target.value; }
  @action updateResourceId(event) { this.resourceId = event.target.value; }

  @action
  async publishTopic(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      await ajax(`/discussion-bridge/v1/publisher/topics/${this.topicId}/publish.json`, { type: "POST" });
      this.notice = i18n("discussion_bridge.admin.publisher_queued");
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  @action
  async importRecord(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      const result = await ajax(`/discussion-bridge/v1/publisher/records/${this.resourceId}/import.json`, { type: "POST" });
      this.notice = i18n("discussion_bridge.admin.publisher_imported");
      this.resourceId = "";
      this.importedTopic = result;
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  <template>
    <section class="discussion-bridge-publishing">
      <header class="discussion-bridge-publishing__hero">
        <div><span aria-hidden="true">DB</span><div><h2>{{i18n "discussion_bridge.admin.publishing_nav"}}</h2><p>{{i18n "discussion_bridge.admin.publishing_description"}}</p></div></div>
        <strong data-ready={{@model.product.ready}}>{{if @model.product.ready (i18n "discussion_bridge.admin.publisher_ready") (i18n "discussion_bridge.admin.needs_attention")}}</strong>
      </header>

      <DPageSubheader @titleLabel={{i18n "discussion_bridge.admin.publishing_nav"}} @descriptionLabel={{@model.product.version}} />

      <div class="discussion-bridge-publishing__metrics">
        <article><span>{{i18n "discussion_bridge.admin.publisher_published_topics"}}</span><strong>{{@model.metrics.published_topics}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_imported_topics"}}</span><strong>{{@model.metrics.imported_topics}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_failed_topics"}}</span><strong>{{@model.metrics.failed_topics}}</strong></article>
      </div>

      <section class="discussion-bridge-publishing__connection">
        <h3>{{i18n "discussion_bridge.admin.publisher_connection"}}</h3>
        <dl>
          <div><dt>{{i18n "discussion_bridge.admin.publisher_receiver"}}</dt><dd><a href={{@model.connection.receiver_url}}>{{@model.connection.receiver_url}}</a></dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.publisher_connection"}}</dt><dd><code>{{@model.connection.connection_id}}</code></dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.publisher_lane"}}</dt><dd><code>{{@model.connection.lane}}</code></dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.publisher_secret_available"}}</dt><dd>{{if @model.connection.secret "Yes" "No"}}</dd></div>
        </dl>
        {{#if @model.product.blockers.length}}<h4>{{i18n "discussion_bridge.admin.publisher_configuration_blockers"}}</h4><ul>{{#each @model.product.blockers as |blocker|}}<li><code>{{blocker}}</code></li>{{/each}}</ul>{{/if}}
      </section>

      {{#if this.notice}}<p class="discussion-bridge-publishing__notice" role="status">{{this.notice}}{{#if this.importedTopic}} · <a href={{this.importedTopic.topic_url}}>Open topic {{this.importedTopic.topic_id}}</a>{{/if}}</p>{{/if}}

      <div class="discussion-bridge-publishing__actions">
        <form {{on "submit" this.publishTopic}}>
          <h3>{{i18n "discussion_bridge.admin.publisher_publish_title"}}</h3>
          <p>{{i18n "discussion_bridge.admin.publisher_publish_description"}}</p>
          <label>{{i18n "discussion_bridge.admin.publisher_local_topic_id"}}<input required min="1" type="number" value={{this.topicId}} {{on "input" this.updateTopicId}} /></label>
          <DButton @type="submit" @label="discussion_bridge.admin.publisher_publish" @disabled={{this.working}} class="btn-primary" />
        </form>
        <form {{on "submit" this.importRecord}}>
          <h3>{{i18n "discussion_bridge.admin.publisher_import_title"}}</h3>
          <p>{{i18n "discussion_bridge.admin.publisher_import_description"}}</p>
          <label>{{i18n "discussion_bridge.admin.publisher_resource_id"}}<input required pattern="[0-9a-fA-F-]{36}" value={{this.resourceId}} {{on "input" this.updateResourceId}} /></label>
          <DButton @type="submit" @label="discussion_bridge.admin.publisher_import" @disabled={{this.working}} class="btn-primary" />
        </form>
      </div>

      <section class="discussion-bridge-publishing__recent">
        <h3>{{i18n "discussion_bridge.admin.publisher_recent_activity"}}</h3>
        <table><thead><tr><th>{{i18n "discussion_bridge.admin.publisher_local_topic"}}</th><th>{{i18n "discussion_bridge.admin.state"}}</th><th>{{i18n "discussion_bridge.admin.publisher_remote_topic"}}</th><th>{{i18n "discussion_bridge.admin.publisher_attempts"}}</th></tr></thead>
          <tbody>{{#each @model.recent_topics as |topic|}}<tr><td><a href={{topic.topic_url}}>{{topic.title}}</a><small><code>{{topic.resource_id}}</code></small></td><td>{{topic.state}}</td><td>{{#if topic.remote_topic_url}}<a href={{topic.remote_topic_url}}>Topic {{topic.remote_topic_id}}</a>{{else}}—{{/if}}</td><td>{{topic.attempts}}</td></tr>{{else}}<tr><td colspan="4">{{i18n "discussion_bridge.admin.publisher_no_activity"}}</td></tr>{{/each}}</tbody>
        </table>
      </section>
    </section>
  </template>
}
