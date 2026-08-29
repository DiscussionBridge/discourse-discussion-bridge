import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeReconciliation extends Component {
  @service router;
  @tracked query = this.args.model.query || "";
  @tracked severity = this.args.model.severity || "";

  @action updateQuery(event) { this.query = event.target.value; }
  @action updateSeverity(event) { this.severity = event.target.value; }
  @action applyFilters(event) { event.preventDefault(); this.goToPage(1); }
  @action previousPage() { this.goToPage(this.args.model.pagination.page - 1); }
  @action nextPage() { this.goToPage(this.args.model.pagination.page + 1); }
  displayToken(value) { return value?.replaceAll("_", " ") || "—"; }
  get previousDisabled() { return this.args.model.pagination.page <= 1; }
  get nextDisabled() { return this.args.model.pagination.page >= this.args.model.pagination.pages; }

  goToPage(page) {
    this.router.transitionTo("adminPlugins.show.discussion-bridge-reconciliation", {
      queryParams: { query: this.query, severity: this.severity, page },
    });
  }

  <template>
    <section class="discussion-bridge-reconciliation">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.reconciliation_title"}}
        @descriptionLabel={{i18n "discussion_bridge.admin.reconciliation_description"}}
      />
      <p>{{i18n "discussion_bridge.admin.reconciliation_boundary"}}</p>
      <a class="btn btn-default" href="/discussion-bridge/admin/reconciliation/report.json" download>{{i18n "discussion_bridge.admin.export_report"}}</a>

      <div class="discussion-bridge-reconciliation__summary" aria-live="polite">
        <section><span>{{i18n "discussion_bridge.admin.issues"}}</span><strong>{{@model.summary.total}}</strong></section>
        <section data-severity="critical"><span>{{i18n "discussion_bridge.admin.critical"}}</span><strong>{{@model.summary.critical}}</strong></section>
        <section data-severity="high"><span>{{i18n "discussion_bridge.admin.high"}}</span><strong>{{@model.summary.high}}</strong></section>
        <section data-severity="medium"><span>{{i18n "discussion_bridge.admin.medium"}}</span><strong>{{@model.summary.medium}}</strong></section>
      </div>

      <form {{on "submit" this.applyFilters}} class="discussion-bridge-reconciliation__controls">
        <label>{{i18n "discussion_bridge.admin.search"}}<input type="search" value={{this.query}} {{on "input" this.updateQuery}} /></label>
        <label>{{i18n "discussion_bridge.admin.severity"}}
          <select {{on "change" this.updateSeverity}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="critical">{{i18n "discussion_bridge.admin.critical"}}</option>
            <option value="high">{{i18n "discussion_bridge.admin.high"}}</option>
            <option value="medium">{{i18n "discussion_bridge.admin.medium"}}</option>
          </select>
        </label>
        <DButton @type="submit" @label="discussion_bridge.admin.apply" />
      </form>

      <div class="discussion-bridge-reconciliation__table-wrap">
        <table>
          <thead><tr><th>{{i18n "discussion_bridge.admin.severity"}}</th><th>{{i18n "discussion_bridge.admin.issue"}}</th><th>{{i18n "discussion_bridge.admin.bridge_record"}}</th><th>{{i18n "discussion_bridge.admin.connection"}}</th><th>{{i18n "discussion_bridge.admin.discussion"}}</th><th>{{i18n "discussion_bridge.admin.recommendation"}}</th></tr></thead>
          <tbody>
            {{#each @model.items as |item|}}
              <tr>
                <td><span class="discussion-bridge-reconciliation__severity" data-severity={{item.severity}}>{{this.displayToken item.severity}}</span></td>
                <td>{{this.displayToken item.code}}</td>
                <td><code>{{item.resource_id}}</code></td>
                <td>{{item.connection_name}}</td>
                <td>{{#if item.topic_id}}<a href="/t/{{item.topic_id}}">Topic {{item.topic_id}}</a>{{else}}—{{/if}}</td>
                <td>{{item.recommendation}}</td>
              </tr>
            {{else}}<tr><td colspan="6">{{i18n "discussion_bridge.admin.no_issues"}}</td></tr>{{/each}}
          </tbody>
        </table>
      </div>

      <div class="discussion-bridge-reconciliation__pagination">
        <DButton @label="discussion_bridge.admin.previous" @disabled={{this.previousDisabled}} @action={{this.previousPage}} />
        <span>{{i18n "discussion_bridge.admin.page"}} {{@model.pagination.page}} / {{@model.pagination.pages}}</span>
        <DButton @label="discussion_bridge.admin.next" @disabled={{this.nextDisabled}} @action={{this.nextPage}} />
      </div>
    </section>
  </template>
}
