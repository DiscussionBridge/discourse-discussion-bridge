import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeOperations extends Component {
  @service router;

  @tracked query = "";
  @tracked direction = "";
  @tracked state = "";
  @tracked connectionId = "";
  @tracked sort = "updated";
  @tracked order = "desc";
  @tracked detail = null;
  @tracked fromConnectionId = "";
  @tracked fromTopicId = "";
  @tracked fromExternalId = "";
  @tracked fromUrl = "";
  @tracked migrationConnectionId = "";
  @tracked migrationExternalId = "";
  @tracked migrationUrl = "";
  @tracked sourceNewUrl = "";
  @tracked sourceNativeConfirmed = false;
  @tracked sourceNotice = "";
  @tracked sourceWorking = false;

  constructor() {
    super(...arguments);
    const filters = this.args.model.filters || {};
    const sorting = this.args.model.sorting || {};
    this.query = filters.query || "";
    this.direction = filters.direction || "";
    this.state = filters.state || "";
    this.connectionId = filters.connection_id || "";
    this.sort = sorting.sort || "updated";
    this.order = sorting.order || "desc";
  }

  @action
  updateQuery(event) { this.query = event.target.value; }

  @action
  updateDirection(event) { this.direction = event.target.value; }

  @action
  updateState(event) { this.state = event.target.value; }

  @action
  updateConnection(event) { this.connectionId = event.target.value; }

  @action
  updateFromConnection(event) { this.fromConnectionId = event.target.value; }

  @action
  updateFromTopic(event) { this.fromTopicId = event.target.value; }

  @action
  updateFromExternal(event) { this.fromExternalId = event.target.value; }

  @action
  updateFromUrl(event) { this.fromUrl = event.target.value; }

  @action
  updateMigrationConnection(event) { this.migrationConnectionId = event.target.value; }

  @action
  updateMigrationExternal(event) { this.migrationExternalId = event.target.value; }

  @action
  updateMigrationUrl(event) { this.migrationUrl = event.target.value; }

  @action
  updateSourceNewUrl(event) { this.sourceNewUrl = event.target.value; }

  @action
  updateSourceNativeConfirmed(event) { this.sourceNativeConfirmed = event.target.checked; }

  get previousDisabled() { return this.args.model.pagination.page <= 1; }
  get nextDisabled() { return this.args.model.pagination.page >= this.args.model.pagination.pages; }
  displayToken(value) { return value?.replaceAll("_", " ") || "—"; }

  publicationLabel(value) {
    return i18n(`discussion_bridge.admin.publication_${value || "not_published"}`);
  }

  sortIndicator(column) {
    if (this.sort !== column) {
      return "";
    }

    return this.order === "asc" ? "▲" : "▼";
  }

  ariaSort(column) {
    if (this.sort !== column) {
      return "none";
    }

    return this.order === "asc" ? "ascending" : "descending";
  }

  connectionSelected(id) {
    return String(id) === String(this.connectionId);
  }

  @action
  filter(event) {
    event.preventDefault();
    this.transition(1);
  }

  @action
  previousPage() { this.transition(this.args.model.pagination.page - 1); }

  @action
  nextPage() { this.transition(this.args.model.pagination.page + 1); }

  @action
  changeSort(column) {
    const nextOrder = this.sort === column && this.order === "asc" ? "desc" : "asc";
    this.sort = column;
    this.order = nextOrder;
    this.transition(1);
  }

  transition(page) {
    this.router.transitionTo("adminPlugins.show.discussion-bridge-operations", {
      queryParams: {
        query: this.query,
        direction: this.direction,
        state: this.state,
        connection_id: this.connectionId,
        sort: this.sort,
        order: this.order,
        page,
      },
    });
  }

  @action
  async showRecord(record) {
    try {
      const result = await ajax(`/discussion-bridge/admin/bridge-records/${record.id}.json`);
      this.detail = result.bridge_record;
      this.sourceNewUrl = "";
      this.sourceNativeConfirmed = false;
      this.sourceNotice = "";
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

  @action
  async migrateSourceUrl(event) {
    event.preventDefault();
    this.sourceWorking = true;
    this.sourceNotice = "";
    try {
      const result = await ajax(
        `/discussion-bridge/admin/bridge-records/${this.detail.id}/migrate-source-url.json`,
        {
          type: "PUT",
          data: {
            migration: {
              old_url: this.detail.active_binding.canonical_url,
              new_url: this.sourceNewUrl,
              external_id: this.detail.active_binding.external_id,
              native_identity_confirmed: this.sourceNativeConfirmed,
            },
          },
        }
      );
      this.detail = result.bridge_record;
      this.sourceNewUrl = "";
      this.sourceNativeConfirmed = false;
      this.sourceNotice = i18n("discussion_bridge.admin.source_url_migrated");
    } catch (error) { popupAjaxError(error); }
    finally { this.sourceWorking = false; }
  }

  <template>
    <section class="discussion-bridge-operations">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.bridge_records_title"}}
        @descriptionLabel={{i18n "discussion_bridge.admin.bridge_records_description"}}
      />

      <div class="discussion-bridge-direction-cards">
        <section data-direction="to_discourse"><strong>{{i18n "discussion_bridge.admin.to_discourse"}}</strong><p>{{i18n "discussion_bridge.admin.to_discourse_description"}}</p></section>
        <section data-direction="from_discourse"><strong>{{i18n "discussion_bridge.admin.from_discourse"}}</strong><p>{{i18n "discussion_bridge.admin.from_discourse_description"}}</p></section>
      </div>

      <form {{on "submit" this.filter}} class="discussion-bridge-operations__search">
        <label>{{i18n "discussion_bridge.admin.search"}}<input type="search" value={{this.query}} {{on "input" this.updateQuery}} /></label>
        <label>{{i18n "discussion_bridge.admin.content_direction"}}
          <select {{on "change" this.updateDirection}}>
            <option value="" selected={{eq this.direction ""}}>{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="to_discourse" selected={{eq this.direction "to_discourse"}}>{{i18n "discussion_bridge.admin.to_discourse"}}</option>
            <option value="from_discourse" selected={{eq this.direction "from_discourse"}}>{{i18n "discussion_bridge.admin.from_discourse"}}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.status"}}
          <select {{on "change" this.updateState}}>
            <option value="" selected={{eq this.state ""}}>{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="healthy" selected={{eq this.state "healthy"}}>{{i18n "discussion_bridge.admin.healthy"}}</option>
            <option value="migration" selected={{eq this.state "migration"}}>{{i18n "discussion_bridge.admin.migration"}}</option>
            <option value="attention" selected={{eq this.state "attention"}}>{{i18n "discussion_bridge.admin.needs_attention"}}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.connection"}}
          <select {{on "change" this.updateConnection}}>
            <option value="" selected={{eq this.connectionId ""}}>{{i18n "discussion_bridge.admin.all"}}</option>
            {{#each @model.content_connections as |connection|}}<option value={{connection.id}} selected={{this.connectionSelected connection.id}}>{{connection.name}}</option>{{/each}}
          </select>
        </label>
        <DButton @type="submit" @label="discussion_bridge.admin.apply" class="btn-primary" />
      </form>

      <div class="discussion-bridge-operations__table-wrap">
        <table>
          <thead>
            <tr>
              <th aria-sort={{this.ariaSort "title"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "title")}}>{{i18n "discussion_bridge.admin.bridge_record"}} <span aria-hidden="true">{{this.sortIndicator "title"}}</span></button></th>
              <th aria-sort={{this.ariaSort "connection"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "connection")}}>{{i18n "discussion_bridge.admin.connection"}} <span aria-hidden="true">{{this.sortIndicator "connection"}}</span></button></th>
              <th aria-sort={{this.ariaSort "direction"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "direction")}}>{{i18n "discussion_bridge.admin.content_direction"}} <span aria-hidden="true">{{this.sortIndicator "direction"}}</span></button></th>
              <th aria-sort={{this.ariaSort "topic"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "topic")}}>{{i18n "discussion_bridge.admin.discussion"}} <span aria-hidden="true">{{this.sortIndicator "topic"}}</span></button></th>
              <th aria-sort={{this.ariaSort "publication"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "publication")}}>{{i18n "discussion_bridge.admin.publication"}} <span aria-hidden="true">{{this.sortIndicator "publication"}}</span></button></th>
              <th aria-sort={{this.ariaSort "status"}}><button type="button" class="discussion-bridge-operations__sort" {{on "click" (fn this.changeSort "status")}}>{{i18n "discussion_bridge.admin.status"}} <span aria-hidden="true">{{this.sortIndicator "status"}}</span></button></th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {{#each @model.bridge_records as |record|}}
              <tr>
                <td><strong>{{record.title}}</strong><small><code>{{record.resource_id}}</code></small></td>
                <td>{{record.connection_names}}</td>
                <td><span class="discussion-bridge-direction" data-direction={{record.direction}}>{{this.displayToken record.direction}}</span></td>
                <td>{{#if record.topic_id}}<a href="/t/{{record.topic_id}}">Topic {{record.topic_id}} · {{record.reply_count}} replies</a>{{else}}—{{/if}}</td>
                <td><span class="discussion-bridge-publication" data-state={{record.publication_state}}>{{this.publicationLabel record.publication_state}}</span></td>
                <td><span class="discussion-bridge-status" data-state={{record.operational_state}}>{{this.displayToken record.operational_state}}</span></td>
                <td><DButton @label="discussion_bridge.admin.view" @action={{this.showRecord}} @actionParam={{record}} class="btn-primary" /></td>
              </tr>
            {{else}}<tr><td colspan="7">{{i18n "discussion_bridge.admin.no_records"}}</td></tr>{{/each}}
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
          {{#if this.detail.publication_work}}
            <h4>{{i18n "discussion_bridge.admin.publication_status"}}</h4>
            <p><strong>{{this.displayToken this.detail.publication_work.state}}</strong> · {{this.displayToken this.detail.publication_work.action}}</p>
            {{#if this.detail.publication_work.reason}}<p>{{i18n "discussion_bridge.admin.reason"}}: <code>{{this.detail.publication_work.reason}}</code></p>{{/if}}
            {{#if this.detail.publication_work.last_error_detail}}<p>{{this.detail.publication_work.last_error_detail}}</p>{{/if}}
          {{/if}}
          <h4>{{i18n "discussion_bridge.admin.bindings"}}</h4>
          <ul>
            {{#each this.detail.bindings as |binding|}}
              <li><strong>{{binding.connection.name}}</strong> · {{this.displayToken binding.role}} · {{this.displayToken binding.state}} · <a href={{binding.canonical_url}}>{{binding.canonical_url}}</a>
                {{#if (eq binding.state "prepared")}}<DButton @label="discussion_bridge.admin.apply_migration" @action={{this.applyMigration}} @actionParam={{binding}} />{{/if}}
              </li>
            {{/each}}
          </ul>
          <p>{{i18n "discussion_bridge.admin.stable_record_message"}}</p>

          {{#if (eq this.detail.direction "to_discourse")}}
            {{#if (eq this.detail.state "healthy")}}
              <form class="discussion-bridge-operations__source-url-form" {{on "submit" this.migrateSourceUrl}}>
                <h4>{{i18n "discussion_bridge.admin.migrate_source_url"}}</h4>
                <p>{{i18n "discussion_bridge.admin.migrate_source_url_description"}}</p>
                <p><strong>{{i18n "discussion_bridge.admin.source_platform_id"}}</strong> <code>{{this.detail.active_binding.external_id}}</code></p>
                <p><strong>{{i18n "discussion_bridge.admin.source_old_url"}}</strong> <code>{{this.detail.active_binding.canonical_url}}</code></p>
                <label>{{i18n "discussion_bridge.admin.source_new_url"}}<input required type="url" value={{this.sourceNewUrl}} {{on "input" this.updateSourceNewUrl}} /></label>
                <label class="discussion-bridge-operations__confirmation"><input required type="checkbox" checked={{this.sourceNativeConfirmed}} {{on "change" this.updateSourceNativeConfirmed}} />{{i18n "discussion_bridge.admin.source_native_confirmation"}}</label>
                <DButton @type="submit" @disabled={{this.sourceWorking}} @label="discussion_bridge.admin.source_verify_and_migrate" class="btn-primary" />
                {{#if this.sourceNotice}}<p role="status" class="discussion-bridge-operations__notice"><strong>{{this.sourceNotice}}</strong></p>{{/if}}
              </form>
            {{/if}}
          {{/if}}

          <form {{on "submit" this.prepareMigration}}>
            <h4>{{i18n "discussion_bridge.admin.prepare_migration"}}</h4>
            <select required {{on "change" this.updateMigrationConnection}}><option value="" selected={{eq this.migrationConnectionId ""}} disabled>{{i18n "discussion_bridge.admin.select_connection"}}</option>{{#each @model.content_connections as |connection|}}<option value={{connection.id}}>{{connection.name}}</option>{{/each}}</select>
            <input required placeholder={{i18n "discussion_bridge.admin.external_id"}} value={{this.migrationExternalId}} {{on "input" this.updateMigrationExternal}} />
            <input required type="url" placeholder={{i18n "discussion_bridge.admin.canonical_url"}} value={{this.migrationUrl}} {{on "input" this.updateMigrationUrl}} />
            <DButton @type="submit" @label="discussion_bridge.admin.prepare_migration" />
          </form>
        </section>
      {{/if}}

      <form class="discussion-bridge-create-from" {{on "submit" this.createFromDiscourse}}>
        <h3>{{i18n "discussion_bridge.admin.create_from_discourse"}}</h3>
        <p>{{i18n "discussion_bridge.admin.create_from_discourse_description"}}</p>
        <label>{{i18n "discussion_bridge.admin.connection"}}<select required {{on "change" this.updateFromConnection}}><option value="" selected={{eq this.fromConnectionId ""}} disabled>{{i18n "discussion_bridge.admin.select_connection"}}</option>{{#each @model.content_connections as |connection|}}<option value={{connection.id}}>{{connection.name}}</option>{{/each}}</select></label>
        <label class="discussion-bridge-create-from__topic-id">{{i18n "discussion_bridge.admin.topic_id"}}<input required type="number" min="1" max="999999999999" inputmode="numeric" value={{this.fromTopicId}} {{on "input" this.updateFromTopic}} /></label>
        <input required placeholder={{i18n "discussion_bridge.admin.external_id"}} value={{this.fromExternalId}} {{on "input" this.updateFromExternal}} />
        <input required type="url" placeholder={{i18n "discussion_bridge.admin.presentation_url"}} value={{this.fromUrl}} {{on "input" this.updateFromUrl}} />
        <DButton @type="submit" @label="discussion_bridge.admin.create_bridge_record" class="btn-primary" />
      </form>
    </section>
  </template>
}
