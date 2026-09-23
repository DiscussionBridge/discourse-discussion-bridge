import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { eq, not, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperatorConsole extends Component {
  @tracked publicationWork = this.args.model.publication_work ?? [];
  @tracked pagination = this.args.model.publication_work_pagination;
  @tracked working = false;

  get canMutate() {
    return this.args.model.operator_access?.can_mutate;
  }

  get attentionCount() {
    const work = this.args.model.metrics.publication_work ?? {};
    return (work.attention ?? 0) + (work.failed ?? 0);
  }

  @action
  async retry(item) {
    if (!this.canMutate) {
      return;
    }
    this.working = true;
    try {
      await ajax(
        `/discussion-bridge/admin/publishing/work/${item.id}/retry.json`,
        { type: "POST" }
      );
      await this.loadPage(this.pagination.page);
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  @action
  async loadPage(page) {
    this.working = true;
    try {
      const result = await ajax("/discussion-bridge/admin/publishing.json", {
        data: { publication_page: page },
      });
      this.publicationWork = result.publication_work;
      this.pagination = result.publication_work_pagination;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  <template>
    <div class="wrap discussion-bridge-operator-console">
      <header>
        <div>
          <span aria-hidden="true">DB</span>
          <div>
            <h1>{{i18n "discussion_bridge.operator_console.title"}}</h1>
            <p>{{i18n "discussion_bridge.operator_console.description"}}</p>
          </div>
        </div>
        <strong data-state={{@model.operator_access.status}}>{{@model.operator_access.status}}</strong>
      </header>

      {{#unless this.canMutate}}
        <p class="discussion-bridge-operator-console__read-only" role="status">{{i18n
            "discussion_bridge.operator_console.read_only"
          }}</p>
      {{/unless}}

      <section class="discussion-bridge-operator-console__metrics">
        <article><span>{{i18n "discussion_bridge.admin.publisher_published_topics"}}</span><strong>{{@model.metrics.published_topics}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_connected_platforms"}}</span><strong>{{@model.metrics.connected_platforms}}</strong></article>
        <article><span>{{i18n "discussion_bridge.admin.publisher_queue_attention"}}</span><strong>{{this.attentionCount}}</strong></article>
      </section>

      <section>
        <h2>{{i18n "discussion_bridge.operator_console.attention_queue"}}</h2>
        <table>
          <thead><tr><th>{{i18n "discussion_bridge.admin.bridge_record"}}</th><th>{{i18n "discussion_bridge.admin.connection_name"}}</th><th>{{i18n "discussion_bridge.admin.status"}}</th><th>{{i18n "discussion_bridge.admin.actions"}}</th></tr></thead>
          <tbody>
            {{#each this.publicationWork as |item|}}
              <tr>
                <td><a href={{item.topic_url}}>{{item.title}}</a></td>
                <td>{{item.connection_name}}</td>
                <td>{{item.state}}{{#if item.last_error_code}} · {{item.last_error_code}}{{/if}}</td>
                <td>{{#if (eq item.state "failed")}}<DButton @label="discussion_bridge.admin.retry_publication" @action={{fn this.retry item}} @disabled={{or this.working (not this.canMutate)}} />{{else}}—{{/if}}</td>
              </tr>
            {{else}}
              <tr><td colspan="4">{{i18n "discussion_bridge.operator_console.no_work"}}</td></tr>
            {{/each}}
          </tbody>
        </table>
      </section>

      <section>
        <h2>{{i18n "discussion_bridge.operator_console.audit_log"}}</h2>
        <table>
          <thead><tr><th>{{i18n "discussion_bridge.operator_console.time"}}</th><th>{{i18n "discussion_bridge.operator_console.event"}}</th><th>{{i18n "discussion_bridge.operator_console.actor"}}</th><th>{{i18n "discussion_bridge.admin.connection_name"}}</th></tr></thead>
          <tbody>
            {{#each @model.operator_events as |event|}}
              <tr>
                <td>{{event.created_at}}</td>
                <td>{{event.event_type}}</td>
                <td>{{event.actor_username}}{{#unless event.actor_username}}DiscussionBridge{{/unless}}</td>
                <td>{{event.connection_name}}{{#unless event.connection_name}}—{{/unless}}</td>
              </tr>
            {{else}}
              <tr><td colspan="4">{{i18n "discussion_bridge.operator_console.no_audit_events"}}</td></tr>
            {{/each}}
          </tbody>
        </table>
      </section>
    </div>
  </template>
}
