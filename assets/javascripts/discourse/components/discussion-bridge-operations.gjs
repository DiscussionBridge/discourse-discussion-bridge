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

  get previousDisabled() {
    return this.args.model.pagination.page <= 1;
  }

  get nextDisabled() {
    return this.args.model.pagination.page >= this.args.model.pagination.pages;
  }

  @action
  updateQuery(event) {
    this.query = event.target.value;
  }

  @action
  updateDirection(event) {
    this.direction = event.target.value;
  }

  @action
  updateState(event) {
    this.state = event.target.value;
  }

  @action
  updateConnection(event) {
    this.connectionId = event.target.value;
  }

  @action
  updateFromConnection(event) {
    this.fromConnectionId = event.target.value;
  }

  @action
  updateFromTopic(event) {
    this.fromTopicId = event.target.value;
  }

  @action
  updateFromExternal(event) {
    this.fromExternalId = event.target.value;
  }

  @action
  updateFromUrl(event) {
    this.fromUrl = event.target.value;
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  @action
  filter(event) {
    event.preventDefault();
    this.transition(1);
  }

  @action
  previousPage() {
    this.transition(this.args.model.pagination.page - 1);
  }

  @action
  nextPage() {
    this.transition(this.args.model.pagination.page + 1);
  }

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
      const result = await ajax(
        `/discussion-bridge/admin/bridge-records/${record.id}.json`
      );
      this.detail = result.bridge_record;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async createFromDiscourse(event) {
    event.preventDefault();
    try {
      const result = await ajax(
        "/discussion-bridge/admin/bridge-records.json",
        {
          type: "POST",
          data: {
            bridge_record: {
              content_connection_id: this.fromConnectionId,
              topic_id: this.fromTopicId,
              external_id: this.fromExternalId,
              canonical_url: this.fromUrl,
            },
          },
        }
      );
      this.detail = result.bridge_record;
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <section class="discussion-bridge-operations">
      <DPageSubheader
        @descriptionLabel={{i18n
          "discussion_bridge.admin.bridge_records_description"
        }}
        @titleLabel={{i18n "discussion_bridge.admin.bridge_records_title"}}
      />

      <div class="discussion-bridge-direction-cards">
        <section><strong>{{i18n
              "discussion_bridge.admin.to_discourse"
            }}</strong><p>{{i18n
              "discussion_bridge.admin.to_discourse_description"
            }}</p></section>
        <section><strong>{{i18n
              "discussion_bridge.admin.from_discourse"
            }}</strong><p>{{i18n
              "discussion_bridge.admin.from_discourse_description"
            }}</p></section>
      </div>

      <form
        class="discussion-bridge-operations__search"
        {{on "submit" this.filter}}
      >
        <label>{{i18n "discussion_bridge.admin.search"}}<input
            type="search"
            value={{this.query}}
            {{on "input" this.updateQuery}}
          /></label>
        <label>{{i18n "discussion_bridge.admin.content_direction"}}
          <select {{on "change" this.updateDirection}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="to_discourse">{{i18n
                "discussion_bridge.admin.to_discourse"
              }}</option>
            <option value="from_discourse">{{i18n
                "discussion_bridge.admin.from_discourse"
              }}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.status"}}
          <select {{on "change" this.updateState}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            <option value="healthy">{{i18n
                "discussion_bridge.admin.healthy"
              }}</option>
            <option value="attention">{{i18n
                "discussion_bridge.admin.needs_attention"
              }}</option>
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.connection"}}
          <select {{on "change" this.updateConnection}}>
            <option value="">{{i18n "discussion_bridge.admin.all"}}</option>
            {{#each @model.content_connections as |connection|}}<option
                value={{connection.id}}
              >{{connection.name}}</option>{{/each}}
          </select>
        </label>
        <DButton @label="discussion_bridge.admin.apply" @type="submit" />
      </form>

      <div class="discussion-bridge-operations__table-wrap">
        <table>
          <thead><tr><th>{{i18n
                  "discussion_bridge.admin.bridge_record"
                }}</th><th>{{i18n "discussion_bridge.admin.connection"}}</th><th
              >{{i18n "discussion_bridge.admin.content_direction"}}</th><th
              >{{i18n "discussion_bridge.admin.discussion"}}</th><th>{{i18n
                  "discussion_bridge.admin.status"
                }}</th><th></th></tr></thead>
          <tbody>
            {{#each @model.bridge_records as |record|}}
              <tr>
                <td><strong>{{record.title}}</strong><small><code
                    >{{record.resource_id}}</code></small></td>
                <td>{{record.connection_names}}</td>
                <td><span
                    class="discussion-bridge-direction"
                    data-direction={{record.direction}}
                  >{{this.displayToken record.direction}}</span></td>
                <td>{{#if record.topic_id}}<a
                      href="/t/{{record.topic_id}}"
                    >Topic
                      {{record.topic_id}}
                      ·
                      {{record.reply_count}}
                      replies</a>{{else}}—{{/if}}</td>
                <td><span
                    class="discussion-bridge-status"
                    data-state={{record.state}}
                  >{{this.displayToken record.state}}</span></td>
                <td><DButton
                    @action={{this.showRecord}}
                    @actionParam={{record}}
                    @label="discussion_bridge.admin.view"
                  /></td>
              </tr>
            {{else}}<tr><td colspan="6">{{i18n
                    "discussion_bridge.admin.no_records"
                  }}</td></tr>{{/each}}
          </tbody>
        </table>
      </div>

      <div class="discussion-bridge-operations__pagination">
        <DButton
          @action={{this.previousPage}}
          @disabled={{this.previousDisabled}}
          @label="discussion_bridge.admin.previous"
        />
        <span>{{i18n "discussion_bridge.admin.page"}}
          {{@model.pagination.page}}
          /
          {{@model.pagination.pages}}</span>
        <DButton
          @action={{this.nextPage}}
          @disabled={{this.nextDisabled}}
          @label="discussion_bridge.admin.next"
        />
      </div>

      {{#if this.detail}}
        <section class="discussion-bridge-record-detail">
          <h3>{{this.detail.title}}</h3>
          <p><strong>{{i18n
                "discussion_bridge.admin.content_direction"
              }}:</strong>
            {{this.displayToken this.detail.direction}}</p>
          <p><strong>{{i18n "discussion_bridge.admin.discussion"}}:</strong>
            <a href={{this.detail.topic_url}}>Topic
              {{this.detail.topic_id}}</a></p>
          <p><code>{{this.detail.resource_id}}</code></p>
          <h4>{{i18n "discussion_bridge.admin.bindings"}}</h4>
          <ul>
            {{#each this.detail.bindings as |binding|}}
              <li><strong>{{binding.connection.name}}</strong>
                ·
                {{this.displayToken binding.role}}
                ·
                {{this.displayToken binding.state}}
                ·
                <a href={{binding.canonical_url}}>{{binding.canonical_url}}</a>
              </li>
            {{/each}}
          </ul>
          <p>{{i18n "discussion_bridge.admin.stable_record_message"}}</p>

        </section>
      {{/if}}

      <form
        class="discussion-bridge-create-from"
        {{on "submit" this.createFromDiscourse}}
      >
        <h3>{{i18n "discussion_bridge.admin.create_from_discourse"}}</h3>
        <p>{{i18n
            "discussion_bridge.admin.create_from_discourse_description"
          }}</p>
        <select required {{on "change" this.updateFromConnection}}><option
            value=""
          >—</option>{{#each @model.content_connections as |connection|}}<option
              value={{connection.id}}
            >{{connection.name}}</option>{{/each}}</select>
        <input
          min="1"
          placeholder={{i18n "discussion_bridge.admin.topic_id"}}
          required
          type="number"
          value={{this.fromTopicId}}
          {{on "input" this.updateFromTopic}}
        />
        <input
          placeholder={{i18n "discussion_bridge.admin.external_id"}}
          required
          value={{this.fromExternalId}}
          {{on "input" this.updateFromExternal}}
        />
        <input
          placeholder={{i18n "discussion_bridge.admin.presentation_url"}}
          required
          type="url"
          value={{this.fromUrl}}
          {{on "input" this.updateFromUrl}}
        />
        <DButton
          class="btn-primary"
          @label="discussion_bridge.admin.create_bridge_record"
          @type="submit"
        />
      </form>
    </section>
  </template>
}
