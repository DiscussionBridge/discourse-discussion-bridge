import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperatorService extends Component {
  @tracked state;
  @tracked operatorUsername;
  @tracked issuerId = "";
  @tracked keyId = "";
  @tracked publicKey = "";
  @tracked entitlementJson = "";
  @tracked notice = "";
  @tracked working = false;

  constructor(owner, args) {
    super(owner, args);
    this.state = this.args.model;
    this.operatorUsername = this.args.model.operator_username || "";
  }

  @action
  updateOperatorUsername(event) {
    this.operatorUsername = event.target.value;
  }

  @action
  updateIssuerId(event) {
    this.issuerId = event.target.value;
  }

  @action
  updateKeyId(event) {
    this.keyId = event.target.value;
  }

  @action
  updatePublicKey(event) {
    this.publicKey = event.target.value;
  }

  @action
  updateEntitlementJson(event) {
    this.entitlementJson = event.target.value;
  }

  @action
  async toggleEnabled(event) {
    await this.updateService({ enabled: event.target.checked });
  }

  @action
  async saveOperatorUser(event) {
    event.preventDefault();
    await this.updateService({ operator_username: this.operatorUsername });
  }

  @action
  async enrollKey(event) {
    event.preventDefault();
    await this.mutate(
      "/discussion-bridge/admin/operator-service/trusted-keys.json",
      {
        type: "POST",
        data: {
          trusted_key: {
            issuer_id: this.issuerId,
            key_id: this.keyId,
            public_key_base64url: this.publicKey,
          },
        },
      }
    );
    this.notice = i18n("discussion_bridge.admin.operator_key_enrolled");
  }

  @action
  async revokeKey(key) {
    await this.mutate(
      `/discussion-bridge/admin/operator-service/trusted-keys/${key.id}.json`,
      { type: "DELETE" }
    );
    this.notice = i18n("discussion_bridge.admin.operator_key_revoked");
  }

  @action
  async enrollEntitlement(event) {
    event.preventDefault();
    let entitlement;
    try {
      entitlement = JSON.parse(this.entitlementJson);
    } catch {
      this.notice = i18n(
        "discussion_bridge.admin.operator_entitlement_invalid_json"
      );
      return;
    }
    await this.mutate(
      "/discussion-bridge/admin/operator-service/entitlements.json",
      {
        type: "POST",
        contentType: "application/json",
        data: JSON.stringify({ entitlement }),
      }
    );
    this.notice = i18n("discussion_bridge.admin.operator_entitlement_enrolled");
  }

  @action
  async revokeEntitlement() {
    await this.mutate(
      "/discussion-bridge/admin/operator-service/entitlements/current.json",
      { type: "DELETE" }
    );
    this.notice = i18n("discussion_bridge.admin.operator_entitlement_revoked");
  }

  async updateService(operatorService) {
    await this.mutate("/discussion-bridge/admin/operator-service.json", {
      type: "PUT",
      data: { operator_service: operatorService },
    });
    this.notice = i18n("discussion_bridge.admin.operator_service_saved");
  }

  async mutate(url, options) {
    this.working = true;
    this.notice = "";
    try {
      this.state = await ajax(url, options);
    } catch (error) {
      popupAjaxError(error);
      throw error;
    } finally {
      this.working = false;
    }
  }

  display(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  <template>
    <section class="discussion-bridge-operator-service">
      <header class="discussion-bridge-operator-service__hero">
        <div><span aria-hidden="true">DB</span><div><h2>{{i18n
                "discussion_bridge.admin.operator_service_nav"
              }}</h2><p>{{i18n
                "discussion_bridge.admin.operator_service_description"
              }}</p></div></div>
        <strong>{{this.display this.state.state}}</strong>
      </header>

      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.operator_service_nav"}}
        @descriptionLabel={{this.state.provider_name}}
      />

      {{#if this.notice}}<p
          class="alert alert-success"
        >{{this.notice}}</p>{{/if}}

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_local_control"}}</h3>
        <p>{{i18n
            "discussion_bridge.admin.operator_local_control_description"
          }}</p>
        <label><input
            type="checkbox"
            checked={{this.state.enabled}}
            disabled={{this.working}}
            {{on "change" this.toggleEnabled}}
          />
          {{i18n "discussion_bridge.admin.operator_enable"}}</label>
        <dl><div><dt>{{i18n
                "discussion_bridge.admin.operator_forum_id"
              }}</dt><dd>{{this.state.forum_id}}</dd></div><div><dt>{{i18n
                "discussion_bridge.admin.operator_provider"
              }}</dt><dd>{{this.state.provider_name}}</dd></div></dl>
      </section>

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_account"}}</h3>
        <form {{on "submit" this.saveOperatorUser}}><label>{{i18n
              "discussion_bridge.admin.operator_username"
            }}<input
              value={{this.operatorUsername}}
              {{on "input" this.updateOperatorUsername}}
            /></label><DButton
            @type="submit"
            @label="discussion_bridge.admin.save"
            @disabled={{this.working}}
          /></form>
      </section>

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_trusted_keys"}}</h3>
        <p>{{i18n
            "discussion_bridge.admin.operator_trusted_keys_description"
          }}</p>
        <form {{on "submit" this.enrollKey}}><label>Issuer ID<input
              value={{this.issuerId}}
              {{on "input" this.updateIssuerId}}
            /></label><label>Key ID<input
              value={{this.keyId}}
              {{on "input" this.updateKeyId}}
            /></label><label>Ed25519 public key<input
              value={{this.publicKey}}
              {{on "input" this.updatePublicKey}}
            /></label><DButton
            @type="submit"
            @label="discussion_bridge.admin.operator_enroll_key"
            @disabled={{this.working}}
          /></form>
        <ul>{{#each this.state.trusted_keys as |key|}}<li><code
              >{{key.issuer_id}}:{{key.key_id}}</code>
              —
              {{if key.revoked_at "revoked" "trusted"}}
              {{#unless key.revoked_at}}<DButton
                  @action={{fn this.revokeKey key}}
                  @label="discussion_bridge.admin.operator_revoke"
                  @disabled={{this.working}}
                />{{/unless}}</li>{{/each}}</ul>
      </section>

      <section class="discussion-bridge-operator-service__panel">
        <h3>{{i18n "discussion_bridge.admin.operator_entitlement"}}</h3>
        <p>{{i18n
            "discussion_bridge.admin.operator_entitlement_description"
          }}</p>
        {{#if this.state.entitlement}}<dl><div><dt>ID</dt><dd
              >{{this.state.entitlement.entitlement_id}}</dd></div><div><dt
              >State</dt><dd>{{this.display
                  this.state.entitlement.state
                }}</dd></div><div><dt>Scopes</dt><dd
              >{{this.state.entitlement.scopes}}</dd></div></dl><DButton
            @action={{this.revokeEntitlement}}
            @label="discussion_bridge.admin.operator_revoke_entitlement"
            @disabled={{this.working}}
          />{{else}}<form {{on "submit" this.enrollEntitlement}}><label>{{i18n
                "discussion_bridge.admin.operator_entitlement_json"
              }}<textarea
                value={{this.entitlementJson}}
                {{on "input" this.updateEntitlementJson}}
              ></textarea></label><DButton
              @type="submit"
              @label="discussion_bridge.admin.operator_enroll_entitlement"
              @disabled={{this.working}}
            /></form>{{/if}}
      </section>

      <section class="discussion-bridge-operator-service__panel"><h3>{{i18n
            "discussion_bridge.admin.operator_boundary"
          }}</h3><p>{{i18n
            "discussion_bridge.admin.operator_boundary_description"
          }}</p></section>
    </section>
  </template>
}
