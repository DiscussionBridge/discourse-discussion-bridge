import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperations extends Component {
  @service router;

  @tracked query = this.args.model.query || "";
  @tracked filter = this.args.model.filter || "";

  get mappingsSelected() {
    return this.args.model.kind === "mappings";
  }

  get auditsSelected() {
    return this.args.model.kind === "audits";
  }

  get hasPreviousPage() {
    return this.args.model.pagination.page > 1;
  }

  get hasNextPage() {
    return this.args.model.pagination.page < this.args.model.pagination.pages;
  }

  get previousDisabled() {
    return !this.hasPreviousPage;
  }

  get nextDisabled() {
    return !this.hasNextPage;
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  shortDigest(value) {
    if (!value || value.length <= 24) {
      return value || "—";
    }

    return `${value.slice(0, 12)}…${value.slice(-8)}`;
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  updateFilter(event) {
    this.filter = event.target.value;
  }

  @action
  search(event) {
    event.preventDefault();
    this.transition(this.args.model.kind, 1);
  }

  @action
  showMappings() {
    this.query = "";
    this.filter = "";
    this.transition("mappings", 1);
  }

  @action
  showAudits() {
    this.query = "";
    this.filter = "";
    this.transition("audits", 1);
  }

  @action
  previousPage() {
    this.transition(this.args.model.kind, this.args.model.pagination.page - 1);
  }

  @action
  nextPage() {
    this.transition(this.args.model.kind, this.args.model.pagination.page + 1);
  }

  transition(kind, page) {
    this.router.transitionTo("adminPlugins.show.discussion-bridge-operations", {
      queryParams: {
        kind,
        query: this.query,
        filter: this.filter,
        page,
      },
    });
  }

  <template>
    <section class="discussion-bridge-operations">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.operations_title"}}
        @descriptionLabel={{i18n
          "discussion_bridge.admin.operations_description"
        }}
      />

      <div class="discussion-bridge-operations__kinds">
        <DButton
          @label="discussion_bridge.admin.mappings"
          @action={{this.showMappings}}
          class={{if this.mappingsSelected "btn-primary" "btn-default"}}
        />
        <DButton
          @label="discussion_bridge.admin.audits"
          @action={{this.showAudits}}
          class={{if this.auditsSelected "btn-primary" "btn-default"}}
        />
      </div>

      <form
        {{on "submit" this.search}}
        class="discussion-bridge-operations__search"
      >
        <label>
          {{i18n "discussion_bridge.admin.search"}}
          <input
            value={{this.query}}
            {{on "input" this.updateQuery}}
            type="search"
          />
        </label>
        <label>
          {{i18n "discussion_bridge.admin.filter"}}
          <input
            value={{this.filter}}
            {{on "input" this.updateFilter}}
            type="text"
          />
        </label>
        <DButton
          @label="discussion_bridge.admin.apply"
          @type="submit"
          class="btn-primary"
        />
      </form>

      <p class="discussion-bridge-operations__summary">
        {{@model.pagination.total}}
        {{i18n "discussion_bridge.admin.records"}}
      </p>

      <div class="discussion-bridge-operations__table-wrap">
        <table class="d-table discussion-bridge-operations__table">
          <thead>
            {{#if this.mappingsSelected}}
              <tr><th class="discussion-bridge-operations__state-column">{{i18n "discussion_bridge.admin.state"}}</th><th>{{i18n
                    "discussion_bridge.admin.source"
                  }}</th><th>{{i18n "discussion_bridge.admin.topic"}}</th><th
                >{{i18n "discussion_bridge.admin.actor"}}</th><th>{{i18n
                    "discussion_bridge.admin.updated"
                  }}</th></tr>
            {{else}}
              <tr><th class="discussion-bridge-operations__state-column">{{i18n "discussion_bridge.admin.outcome"}}</th><th>{{i18n
                    "discussion_bridge.admin.reason"
                  }}</th><th>{{i18n
                    "discussion_bridge.admin.source_digest"
                  }}</th><th>{{i18n "discussion_bridge.admin.topic"}}</th><th
                >{{i18n "discussion_bridge.admin.created"}}</th></tr>
            {{/if}}
          </thead>
          <tbody>
            {{#each @model.items as |item|}}
              {{#if this.mappingsSelected}}
                <tr>
                  <td data-label={{i18n "discussion_bridge.admin.state"}}>
                    <span
                      class="discussion-bridge-operations__status"
                      data-state={{item.state}}
                    >{{this.displayToken item.state}}</span>
                  </td>
                  <td
                    data-label={{i18n "discussion_bridge.admin.source"}}
                    class="discussion-bridge-operations__source"
                  ><a href={{item.source_url}}>{{item.source_url}}</a><small
                    >{{item.connection_id}} · {{item.lane}}</small></td>
                  <td data-label={{i18n "discussion_bridge.admin.topic"}}>{{#if item.topic_id}}<a
                        href="/t/{{item.topic_id}}"
                      >{{item.topic_id}}</a>{{else}}—{{/if}}</td>
                  <td data-label={{i18n "discussion_bridge.admin.actor"}}>{{#if
                      item.actor
                    }}{{item.actor.username}}{{else}}—{{/if}}</td>
                  <td data-label={{i18n "discussion_bridge.admin.updated"}}><time
                      class="discussion-bridge-operations__timestamp"
                    >{{item.updated_at}}</time></td>
                </tr>
              {{else}}
                <tr>
                  <td data-label={{i18n "discussion_bridge.admin.outcome"}}>
                    <span
                      class="discussion-bridge-operations__status"
                      data-state={{item.outcome}}
                    >{{this.displayToken item.outcome}}</span>
                  </td>
                  <td data-label={{i18n "discussion_bridge.admin.reason"}}>{{this.displayToken item.reason}}</td>
                  <td data-label={{i18n "discussion_bridge.admin.source_digest"}}><code
                      class="discussion-bridge-operations__digest"
                      title={{item.source_digest}}
                    >{{this.shortDigest item.source_digest}}</code></td>
                  <td data-label={{i18n "discussion_bridge.admin.topic"}}>{{#if item.topic_id}}<a
                        href="/t/{{item.topic_id}}"
                      >{{item.topic_id}}</a>{{else}}—{{/if}}</td>
                  <td data-label={{i18n "discussion_bridge.admin.created"}}><time
                      class="discussion-bridge-operations__timestamp"
                    >{{item.created_at}}</time></td>
                </tr>
              {{/if}}
            {{else}}
              <tr><td colspan="5">{{i18n
                    "discussion_bridge.admin.no_records"
                  }}</td></tr>
            {{/each}}
          </tbody>
        </table>
      </div>

      <div class="discussion-bridge-operations__pagination">
        <DButton
          @label="discussion_bridge.admin.previous"
          @action={{this.previousPage}}
          @disabled={{this.previousDisabled}}
        />
        <span>{{i18n "discussion_bridge.admin.page"}}
          {{@model.pagination.page}}
          /
          {{@model.pagination.pages}}</span>
        <DButton
          @label="discussion_bridge.admin.next"
          @action={{this.nextPage}}
          @disabled={{this.nextDisabled}}
        />
      </div>
    </section>
  </template>
}
