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

export default class DiscussionBridgeConnections extends Component {
  @service router;
  @service dialog;

  @tracked name = "";
  @tracked platform = "wordpress";
  @tracked authorUsername = "";
  @tracked origins = "";
  @tracked lanes = "";
  @tracked toDiscourse = true;
  @tracked fromDiscourse = true;
  @tracked issuedSecret = null;
  @tracked issuedConnectionId = null;
  @tracked editingConnectionId = null;

  @action
  updateName(event) { this.name = event.target.value; }

  @action
  updatePlatform(event) { this.platform = event.target.value; }

  @action
  updateAuthorUsername(event) { this.authorUsername = event.target.value; }

  @action
  updateOrigins(event) { this.origins = event.target.value; }

  @action
  updateLanes(event) { this.lanes = event.target.value; }

  @action
  updateToDiscourse(event) { this.toDiscourse = event.target.checked; }

  @action
  updateFromDiscourse(event) { this.fromDiscourse = event.target.checked; }

  @action
  async saveConnection(event) {
    event.preventDefault();
    const directions = [];
    if (this.toDiscourse) { directions.push("to_discourse"); }
    if (this.fromDiscourse) { directions.push("from_discourse"); }
    try {
      const editing = this.editingConnectionId;
      const url = editing
        ? `/discussion-bridge/admin/content-connections/${editing}.json`
        : "/discussion-bridge/admin/content-connections.json";
      const result = await ajax(url, {
        type: editing ? "PUT" : "POST",
        data: {
          content_connection: {
            name: this.name,
            platform: this.platform,
            author_username: this.authorUsername,
            allowed_origins: this.lines(this.origins),
            allowed_directions: directions,
            allowed_lanes: this.lines(this.lanes),
          },
        },
      });
      if (result.secret) {
        this.issuedSecret = result.secret;
        this.issuedConnectionId = result.content_connection.public_id;
      }
      this.resetForm();
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  editConnection(connection) {
    this.editingConnectionId = connection.id;
    this.name = connection.name;
    this.platform = connection.platform;
    this.authorUsername = connection.author_override ? connection.author_username : "";
    this.origins = connection.allowed_origins.join("\n");
    this.lanes = connection.allowed_lanes.join("\n");
    this.toDiscourse = connection.allowed_directions.includes("to_discourse");
    this.fromDiscourse = connection.allowed_directions.includes("from_discourse");
  }

  @action
  cancelEdit() { this.resetForm(); }

  @action
  async toggleConnection(connection) {
    try {
      await ajax(`/discussion-bridge/admin/content-connections/${connection.id}.json`, {
        type: "PUT",
        data: { content_connection: { enabled: !connection.enabled } },
      });
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async rotateSecret(connection) {
    const confirmed = await this.dialog.yesNoConfirm({
      message: i18n("discussion_bridge.admin.rotate_secret_confirm"),
    });
    if (!confirmed) { return; }
    try {
      const result = await ajax(
        `/discussion-bridge/admin/content-connections/${connection.id}/rotate-secret.json`,
        { type: "POST" }
      );
      this.issuedSecret = result.secret;
      this.issuedConnectionId = connection.public_id;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  lines(value) {
    return value.split(/\r?\n/).map((entry) => entry.trim()).filter(Boolean);
  }

  resetForm() {
    this.editingConnectionId = null;
    this.name = "";
    this.platform = "wordpress";
    this.authorUsername = "";
    this.origins = "";
    this.lanes = "";
    this.toDiscourse = true;
    this.fromDiscourse = true;
  }

  displayToken(value) { return value?.replaceAll("_", " ") || "—"; }

  <template>
    <section class="discussion-bridge-connections">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.connections_title"}}
        @descriptionLabel={{i18n "discussion_bridge.admin.connections_description"}}
      />

      {{#if this.issuedSecret}}
        <section class="discussion-bridge-secret" role="status">
          <strong>{{i18n "discussion_bridge.admin.secret_shown_once"}}</strong>
          <p><code>{{this.issuedConnectionId}}</code></p>
          <p><code>{{this.issuedSecret}}</code></p>
        </section>
      {{/if}}

      <div class="discussion-bridge-connection-grid">
        {{#each @model.content_connections as |connection|}}
          <article class="discussion-bridge-connection-card" data-health={{connection.health}}>
            <header>
              <div>
                <span class="discussion-bridge-platform">{{this.displayToken connection.platform}}</span>
                <h3>{{connection.name}}</h3>
              </div>
              <span class="discussion-bridge-status" data-state={{connection.health}}>{{this.displayToken connection.health}}</span>
            </header>
            <dl>
              <dt>{{i18n "discussion_bridge.admin.bridge_records"}}</dt><dd>{{connection.bridge_record_count}}</dd>
              <dt>{{i18n "discussion_bridge.admin.connection_id"}}</dt><dd><code>{{connection.public_id}}</code></dd>
              <dt>{{i18n "discussion_bridge.admin.directions"}}</dt><dd>{{#each connection.allowed_directions as |direction|}}<span>{{this.displayToken direction}}</span>{{/each}}</dd>
              <dt>{{i18n "discussion_bridge.admin.topic_author"}}</dt><dd><code>{{connection.author_username}}</code>{{#unless connection.author_override}} <small>{{i18n "discussion_bridge.admin.forum_default"}}</small>{{/unless}}</dd>
              <dt>{{i18n "discussion_bridge.admin.origins"}}</dt><dd>{{#each connection.allowed_origins as |origin|}}<code>{{origin}}</code>{{/each}}</dd>
            </dl>
            <div class="discussion-bridge-actions">
              <DButton
                @label="discussion_bridge.admin.manage"
                @action={{this.editConnection}}
                @actionParam={{connection}}
              />
              <DButton
                @label={{if connection.enabled "discussion_bridge.admin.disable" "discussion_bridge.admin.enable"}}
                @action={{this.toggleConnection}}
                @actionParam={{connection}}
              />
              <DButton
                @label="discussion_bridge.admin.rotate_secret"
                @action={{this.rotateSecret}}
                @actionParam={{connection}}
              />
            </div>
          </article>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.no_connections"}}</p>
        {{/each}}
      </div>

      <form class="discussion-bridge-add-connection" {{on "submit" this.saveConnection}}>
        <h3>{{if this.editingConnectionId (i18n "discussion_bridge.admin.manage_connection") (i18n "discussion_bridge.admin.add_connection")}}</h3>
        <label>{{i18n "discussion_bridge.admin.connection_name"}}<input required value={{this.name}} {{on "input" this.updateName}} /></label>
        <label>{{i18n "discussion_bridge.admin.platform"}}
          <select {{on "change" this.updatePlatform}}>
            {{#each @model.platforms as |platform|}}<option value={{platform}} selected={{eq platform this.platform}}>{{this.displayToken platform}}</option>{{/each}}
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.topic_author"}}<input value={{this.authorUsername}} {{on "input" this.updateAuthorUsername}} placeholder={{i18n "discussion_bridge.admin.topic_author_default"}} /></label>
        <label>{{i18n "discussion_bridge.admin.allowed_origins"}}<textarea required value={{this.origins}} {{on "input" this.updateOrigins}}></textarea></label>
        <label>{{i18n "discussion_bridge.admin.allowed_lanes"}}<textarea value={{this.lanes}} {{on "input" this.updateLanes}}></textarea></label>
        <fieldset>
          <legend>{{i18n "discussion_bridge.admin.allowed_directions"}}</legend>
          <label><input type="checkbox" checked={{this.toDiscourse}} {{on "change" this.updateToDiscourse}} />{{i18n "discussion_bridge.admin.to_discourse"}}</label>
          <label><input type="checkbox" checked={{this.fromDiscourse}} {{on "change" this.updateFromDiscourse}} />{{i18n "discussion_bridge.admin.from_discourse"}}</label>
        </fieldset>
        <DButton
          @type="submit"
          @label={{if this.editingConnectionId "discussion_bridge.admin.save_connection" "discussion_bridge.admin.add_connection"}}
          class="btn-primary"
        />
        {{#if this.editingConnectionId}}
          <DButton @label="discussion_bridge.admin.cancel" @action={{this.cancelEdit}} />
        {{/if}}
      </form>
    </section>
  </template>
}
