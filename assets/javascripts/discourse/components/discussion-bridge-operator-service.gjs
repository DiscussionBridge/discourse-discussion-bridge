import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperatorService extends Component {
  @tracked state = this.args.model;
  @tracked working = false;
  @tracked notice = "";

  @action
  async setEnabled(enabled) {
    this.working = true;
    this.notice = "";
    try {
      this.state = await ajax(
        "/discussion-bridge/admin/operator-service.json",
        {
          type: "PUT",
          data: { operator_service: { enabled } },
        }
      );
      this.notice = i18n(
        enabled
          ? "discussion_bridge.admin.operator_service_requested"
          : "discussion_bridge.admin.operator_service_disabled"
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  displayDate(value) {
    return value ? new Date(value).toLocaleString() : "—";
  }

  <template>
    <section class="discussion-bridge-operator-service">
      <header class="discussion-bridge-operator-service__hero">
        <div>
          <span aria-hidden="true">DB</span>
          <div>
            <h2>{{i18n "discussion_bridge.admin.operator_service_nav"}}</h2>
            <p>{{i18n
                "discussion_bridge.admin.operator_service_description"
              }}</p>
          </div>
        </div>
        <strong data-state={{this.state.status}}>{{this.state.status}}</strong>
      </header>

      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.operator_service_nav"}}
        @descriptionLabel={{i18n
          "discussion_bridge.admin.operator_service_opt_in"
        }}
      />

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_service_enrollment"}}</h3>
        <p>{{i18n
            "discussion_bridge.admin.operator_service_disclosure"
            email=this.state.service_request_email
          }}</p>
        {{#if this.state.enabled}}
          <DButton
            @label="discussion_bridge.admin.operator_service_disable"
            @action={{fn this.setEnabled false}}
            @disabled={{this.working}}
          />
        {{else}}
          <DButton
            @label="discussion_bridge.admin.operator_service_enable"
            @action={{fn this.setEnabled true}}
            @disabled={{this.working}}
            class="btn-primary"
          />
        {{/if}}
        {{#if this.notice}}<p role="status"><strong>{{this.notice}}</strong></p>{{/if}}
      </section>

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_service_status"}}</h3>
        <dl>
          <div><dt>{{i18n "discussion_bridge.admin.status"}}</dt><dd>{{this.state.status}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_request_destination"}}</dt><dd>{{this.state.service_request_email}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_notification"}}</dt><dd>{{this.state.notification_state}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_grace"}}</dt><dd>{{this.state.grace_period_days}} days</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_operator_email"}}</dt><dd>{{this.state.operator_email}}{{#unless this.state.operator_email}}—{{/unless}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_operator_account"}}</dt><dd>{{this.state.operator_username}}{{#unless this.state.operator_username}}—{{/unless}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_paid_through"}}</dt><dd>{{this.displayDate this.state.paid_through_at}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_grace_expires"}}</dt><dd>{{this.displayDate this.state.grace_expires_at}}</dd></div>
          <div><dt>{{i18n "discussion_bridge.admin.operator_service_mutation_access"}}</dt><dd>{{if this.state.operator_can_mutate "Enabled" "Disabled"}}</dd></div>
        </dl>
      </section>

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_service_boundaries"}}</h3>
        <p>{{i18n "discussion_bridge.admin.operator_service_boundaries_description"}}</p>
      </section>
    </section>
  </template>
}
