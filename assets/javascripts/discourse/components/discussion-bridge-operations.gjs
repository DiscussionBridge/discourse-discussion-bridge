import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperations extends Component {
  @service router;
  @tracked query = "";
  @tracked direction = "";
  @tracked state = "";
  @tracked connectionId = "";
  @tracked detail = null;
  @tracked fromConnectionId = "";
  @tracked fromTopicId = "";
  @tracked fromExternalId = "";
  @tracked fromUrl = "";
  @tracked migrationConnectionId = "";
  @tracked migrationExternalId = "";
  @tracked migrationUrl = "";

  @action updateQuery(event) { this.query = event.target.value; }
  @action updateDirection(event) { this.direction = event.target.value; }
  @action updateState(event) { this.state = event.target.value; }
  @action updateConnection(event) { this.connectionId = event.target.value; }
  @action updateFromConnection(event) { this.fromConnectionId = event.target.value; }
  @action updateFromTopic(event) { this.fromTopicId = event.target.value; }
  @action updateFromExternal(event) { this.fromExternalId = event.target.value; }
  @action updateFromUrl(event) { this.fromUrl = event.target.value; }
  @action updateMigrationConnection(event) { this.migrationConnectionId = event.target.value; }
  @action updateMigrationExternal(event) { this.migrationExternalId = event.target.value; }
  @action updateMigrationUrl(event) { this.migrationUrl = event.target.value; }

  get previousDisabled() { return this.args.model.pagination.page <= 1; }
  get nextDisabled() { return this.args.model.pagination.page >= this.args.model.pagination.pages; }
  displayToken(value) { return value?.replaceAll("_", " ") || "—"; }

  @action
  filter(event) {
    event.preventDefault();
    this.transition(1);
  }

  @action previousPage() { this.transition(this.args.model.pagination.page - 1); }
  @action nextPage() { this.transition(this.args.model.pagination.page + 1); }

  transition(page) {
    this.router.transitionTo("adminPlugins.show.discussion-bridge-operations", {
      queryParams: {
        query: this.query,
        direction: this.direction,
        state: this.state,
        connection_id: this.connectionId,
        page,
      },
    });
  }

  @action
  async showRecord(record) {
    try {
      const result = await ajax(`/discussion-bridge/admin/bridge-records/${record.id}.json`);
      this.detail = result.bridge_record;
    } catch (error) { popupAjaxError(error); }
  }

  @action
  async createFromDiscourse(event) {
    event.preventDefault();
    try {
      const result = await ajax("/discussion-bridge/admin/bridge-records.json", {
        type: "POST",
        data: {
          bridge_record: {
            content_connection_id: this.fromConnectionId,
            topic_id: this.fromTopicId,
            external_id: this.fromExternalId,
            canonical_url: this.fromUrl,
          },
        },
      });
      this.detail = result.bridge_record;
      this.router.refresh();
    } catch (error) { popupAjaxError(error); }
  }

  @action
  async prepareMigration(event) {
    event.preventDefault();
    try {
      const result = await ajax(`/discussion-bridge/admin/bridge-records/${this.detail.id}/migrations.json`, {
        type: "POST",
        data: {
          migration: {
            content_connection_id: this.migrationConnectionId,
            external_id: this.migrationExternalId,
            canonical_url: this.migrationUrl,
          },
        },
      });
      this.detail = result.bridge_record;
      this.router.refresh();
    } catch (error) { popupAjaxError(error); }
  }

  @action
  async applyMigration(binding) {
    try {
      const result = await ajax(
        `/discussion-bridge/admin/bridge-records/${this.detail.id}/migrations/${binding.id}/apply.json`,
        { type: "POST" }
      );
      this.detail = result.bridge_record;
      this.router.refresh();
    } catch (error) { popupAjaxError(error); }
  }

  <template>
    <section class="discussion-bridge-operations">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.bridge_records_title"}}
        @descriptionLabel={{i18n "discussion_bridge.admin.bridge_records_description"}}
      />

      <div class="discussion-bridge-direction-cards">
        <section><strong>{{i18n "discussion_bridge.admin.to_discourse"}}</strong><p>{{i18n "discussion_bridge.admin.to_discourse_description"}}</p></section>
        <section><strong>{{i18n "discussion_bridge.admin.from_discourse"}}</strong><p>{{i18n "discussion_bridge.admin.from_discourse_description"}}</p></section>
      </div>

      <form {{on "submit" this.filter}} class="discussion-bridge-operations__search">
        <label>{{i18n "discussion_bridge.admin.search"}}<input type="search" value={{this.query}} {{on "input" this.updateQuery}} /></label>
        <label>{{i18n "discussion_bridge.admin.content_direction"}}
          <select {{on "change" this.updateDirection}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="to_discourse">{{i18n "discussion_bridge.admin.to_discourse"}}</option>
            <option value="from_discourse">{{i18n "discussion_bridge.admin.from_discourse"}}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.status"}}
          <select {{on "change" this.updateState}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="healthy">{{i18n "discussion_bridge.admin.healthy"}}</option>
            <option value="migration">{{i18n "discussion_bridge.admin.migration"}}</option>
            <option value="attention">{{i18n "discussion_bridge.admin.needs_attention"}}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.connection"}}
          <select {{on "change" this.updateConnection}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            {{#each @model.content_connections as |connection|}}<option value={{connection.id}}>{{connection.name}}</option>{{/each}}
          </select>
        </label>
        <DButton @type="submit" @label="discussion_bridge.admin.apply" />
      </form>

      <div class="discussion-bridge-operations__table-wrap">
        <table>
          <thead><tr><th>{{i18n "discussion_bridge.admin.bridge_record"}}</th><th>{{i18n "discussion_bridge.admin.connection"}}</th><th>{{i18n "discussion_bridge.admin.content_direction"}}</th><th>{{i18n "discussion_bridge.admin.discussion"}}</th><th>{{i18n "discussion_bridge.admin.status"}}</th><th></th></tr></thead>
          <tbody>
            {{#each @model.bridge_records as |record|}}
              <tr>
                <td><strong>{{record.title}}</strong><small><code>{{record.resource_id}}</code></small></td>
                <td>{{record.connection_names}}</td>
                <td><span class="discussion-bridge-direction" data-direction={{record.direction}}>{{this.displayToken record.direction}}</span></td>
                <td>{{#if record.topic_id}}<a href="/t/{{record.topic_id}}">Topic {{record.topic_id}} · {{record.reply_count}} replies</a>{{else}}—{{/if}}</td>
                <td><span class="discussion-bridge-status" data-state={{record.state}}>{{this.displayToken record.state}}</span></td>
                <td><DButton @label="discussion_bridge.admin.view" @action={{this.showRecord}} @actionParam={{record}} /></td>
              </tr>
            {{else}}<tr><td colspan="6">{{i18n "discussion_bridge.admin.no_records"}}</td></tr>{{/each}}
          </tbody>
        </table>
      </div>

      <div class="discussion-bridge-operations__pagination">
        <DButton @label="discussion_bridge.admin.previous" @disabled={{this.previousDisabled}} @action={{this.previousPage}} />
        <span>{{i18n "discussion_bridge.admin.page"}} {{@model.pagination.page}} / {{@model.pagination.pages}}</span>
        <DButton @label="discussion_bridge.admin.next" @disabled={{this.nextDisabled}} @action={{this.nextPage}} />
      </div>

      {{#if this.detail}}
        <section class="discussion-bridge-record-detail">
          <h3>{{this.detail.title}}</h3>
          <p><strong>{{i18n "discussion_bridge.admin.content_direction"}}:</strong> {{this.displayToken this.detail.direction}}</p>
          <p><strong>{{i18n "discussion_bridge.admin.discussion"}}:</strong> <a href={{this.detail.topic_url}}>Topic {{this.detail.topic_id}}</a></p>
          <p><code>{{this.detail.resource_id}}</code></p>
          <h4>{{i18n "discussion_bridge.admin.bindings"}}</h4>
          <ul>
            {{#each this.detail.bindings as |binding|}}
              <li><strong>{{binding.connection.name}}</strong> · {{this.displayToken binding.role}} · {{this.displayToken binding.state}} · <a href={{binding.canonical_url}}>{{binding.canonical_url}}</a>
                {{#if (eq binding.state "prepared")}}<DButton @label="discussion_bridge.admin.apply_migration" @action={{this.applyMigration}} @actionParam={{binding}} />{{/if}}
              </li>
            {{/each}}
          </ul>
          <p>{{i18n "discussion_bridge.admin.stable_record_message"}}</p>

          <form {{on "submit" this.prepareMigration}}>
            <h4>{{i18n "discussion_bridge.admin.prepare_migration"}}</h4>
            <select required {{on "change" this.updateMigrationConnection}}><option value="">—</option>{{#each @model.content_connections as |connection|}}<option value={{connection.id}}>{{connection.name}}</option>{{/each}}</select>
            <input required placeholder={{i18n "discussion_bridge.admin.external_id"}} value={{this.migrationExternalId}} {{on "input" this.updateMigrationExternal}} />
            <input required type="url" placeholder={{i18n "discussion_bridge.admin.canonical_url"}} value={{this.migrationUrl}} {{on "input" this.updateMigrationUrl}} />
            <DButton @type="submit" @label="discussion_bridge.admin.prepare_migration" />
          </form>
        </section>
      {{/if}}

      <form class="discussion-bridge-create-from" {{on "submit" this.createFromDiscourse}}>
        <h3>{{i18n "discussion_bridge.admin.create_from_discourse"}}</h3>
        <p>{{i18n "discussion_bridge.admin.create_from_discourse_description"}}</p>
        <select required {{on "change" this.updateFromConnection}}><option value="">—</option>{{#each @model.content_connections as |connection|}}<option value={{connection.id}}>{{connection.name}}</option>{{/each}}</select>
        <input required type="number" min="1" placeholder={{i18n "discussion_bridge.admin.topic_id"}} value={{this.fromTopicId}} {{on "input" this.updateFromTopic}} />
        <input required placeholder={{i18n "discussion_bridge.admin.external_id"}} value={{this.fromExternalId}} {{on "input" this.updateFromExternal}} />
        <input required type="url" placeholder={{i18n "discussion_bridge.admin.presentation_url"}} value={{this.fromUrl}} {{on "input" this.updateFromUrl}} />
        <DButton @type="submit" @label="discussion_bridge.admin.create_bridge_record" class="btn-primary" />
      </form>
    </section>
  </template>
}
