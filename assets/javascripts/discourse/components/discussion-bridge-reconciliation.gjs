import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeReconciliation extends Component {
  @service router;
  @service dialog;

  @tracked query = this.args.model.query || "";
  @tracked severity = this.args.model.severity || "";

  get criticalSelected() {
    return this.severity === "critical";
  }

  get highSelected() {
    return this.severity === "high";
  }

  get mediumSelected() {
    return this.severity === "medium";
  }

  get previousDisabled() {
    return this.args.model.pagination.page <= 1;
  }

  get nextDisabled() {
    return this.args.model.pagination.page >= this.args.model.pagination.pages;
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  updateSeverity(event) {
    this.severity = event.target.value;
  }

  @action
  applyFilters(event) {
    event.preventDefault();
    this.goToPage(1);
  }

  @action
  goToPage(page) {
    this.router.transitionTo(
      "adminPlugins.show.discussion-bridge-reconciliation",
      {
        queryParams: {
          query: this.query,
          severity: this.severity,
          page,
        },
      }
    );
  }

  @action
  previousPage() {
    this.goToPage(this.args.model.pagination.page - 1);
  }

  @action
  nextPage() {
    this.goToPage(this.args.model.pagination.page + 1);
  }

  @action
  async performAction(item) {
    const authorize = item.action === "authorize_retry";
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n(
        authorize
          ? "discussion_bridge.admin.authorize_retry_confirm"
          : "discussion_bridge.admin.revoke_retry_confirm"
      ),
    });
    if (!confirmed) {
      return;
    }

    try {
      await ajax(
        `/discussion-bridge/admin/reconciliation/${item.mapping_id}/${authorize ? "authorize-retry" : "revoke-retry"}.json`,
        { type: "POST" }
      );
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <section class="discussion-bridge-reconciliation">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.reconciliation_title"}}
        @descriptionLabel={{i18n
          "discussion_bridge.admin.reconciliation_description"
        }}
      />

      <div class="discussion-bridge-reconciliation__summary">
        <section><span>{{i18n "discussion_bridge.admin.issues"}}</span><strong
          >{{@model.summary.total}}</strong></section>
        <section data-severity="critical"><span>{{i18n
              "discussion_bridge.admin.critical"
            }}</span><strong>{{@model.summary.critical}}</strong></section>
        <section data-severity="high"><span>{{i18n
              "discussion_bridge.admin.high"
            }}</span><strong>{{@model.summary.high}}</strong></section>
        <section data-severity="medium"><span>{{i18n
              "discussion_bridge.admin.medium"
            }}</span><strong>{{@model.summary.medium}}</strong></section>
      </div>

      <form
        {{on "submit" this.applyFilters}}
        class="discussion-bridge-reconciliation__controls"
      >
        <label>
          {{i18n "discussion_bridge.admin.search"}}
          <input
            name="query"
            type="search"
            value={{this.query}}
            {{on "input" this.updateQuery}}
          />
        </label>
        <label>
          {{i18n "discussion_bridge.admin.severity"}}
          <select name="severity" {{on "input" this.updateSeverity}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="critical" selected={{this.criticalSelected}}>{{i18n
                "discussion_bridge.admin.critical"
              }}</option>
            <option value="high" selected={{this.highSelected}}>{{i18n
                "discussion_bridge.admin.high"
              }}</option>
            <option value="medium" selected={{this.mediumSelected}}>{{i18n
                "discussion_bridge.admin.medium"
              }}</option>
          </select>
        </label>
        <DButton @type="submit" @label="discussion_bridge.admin.apply" />
      </form>

      <div class="discussion-bridge-reconciliation__table-wrap">
        <table>
          <thead>
            <tr>
              <th>{{i18n "discussion_bridge.admin.severity"}}</th>
              <th>{{i18n "discussion_bridge.admin.issue"}}</th>
              <th>{{i18n "discussion_bridge.admin.source"}}</th>
              <th>{{i18n "discussion_bridge.admin.topic"}}</th>
              <th>{{i18n "discussion_bridge.admin.recommendation"}}</th>
              <th>{{i18n "discussion_bridge.admin.action"}}</th>
            </tr>
          </thead>
          <tbody>
            {{#each @model.items as |item|}}
              <tr>
                <td data-label={{i18n "discussion_bridge.admin.severity"}}><span
                    class="discussion-bridge-reconciliation__severity"
                    data-severity={{item.severity}}
                  >{{this.displayToken item.severity}}</span></td>
                <td data-label={{i18n "discussion_bridge.admin.issue"}}>{{this.displayToken item.code}}</td>
                <td data-label={{i18n "discussion_bridge.admin.source"}}><a
                    href={{item.source_url}}
                    rel="noopener noreferrer"
                  >{{item.source_url}}</a></td>
                <td data-label={{i18n "discussion_bridge.admin.topic"}}>
                  {{#if item.topic_id}}
                    <a href="/t/{{item.topic_id}}">{{item.topic_id}}</a>
                  {{else}}
                    —
                  {{/if}}
                </td>
                <td data-label={{i18n "discussion_bridge.admin.recommendation"}}>{{this.displayToken item.recommendation}}</td>
                <td data-label={{i18n "discussion_bridge.admin.action"}}>
                  {{#if item.action}}
                    <DButton
                      @label={{item.action_label}}
                      @action={{this.performAction}}
                      @actionParam={{item}}
                    />
                  {{else}}
                    —
                  {{/if}}
                </td>
              </tr>
            {{else}}
              <tr><td colspan="6">{{i18n
                    "discussion_bridge.admin.no_issues"
                  }}</td></tr>
            {{/each}}
          </tbody>
        </table>
      </div>

      <div class="discussion-bridge-reconciliation__pagination">
        <DButton
          @label="discussion_bridge.admin.previous"
          @disabled={{this.previousDisabled}}
          @action={{this.previousPage}}
        />
        <span>{{i18n "discussion_bridge.admin.page"}}
          {{@model.pagination.page}}
          /
          {{@model.pagination.pages}}</span>
        <DButton
          @label="discussion_bridge.admin.next"
          @disabled={{this.nextDisabled}}
          @action={{this.nextPage}}
        />
      </div>
    </section>
  </template>
}
