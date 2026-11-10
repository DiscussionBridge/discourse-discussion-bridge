import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn, get, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeConnectionForm extends Component {
  @service router;

  @tracked feedback = "";
  @tracked saving = false;

  constructor() {
    super(...arguments);
    if (this.args.connection) {
      this.applyConnection(this.args.connection);
    }
  }

  @tracked name = "";
  @tracked platform = "";
  @tracked authorUsername = "";
  @tracked authorshipMode = "fixed";
  @tracked unmappedAuthorPolicy = "fallback";
  @tracked sourceMappings = {};
  @tracked origins = "";
  @tracked lanes = "";
  @tracked defaultCategoryId = "";
  @tracked toDiscourse = true;
  @tracked fromDiscourse = true;
  @tracked generateTopicToc = false;

  @action
  updateName(event) {
    this.name = event.target.value;
  }

  @action
  updatePlatform(event) {
    this.platform = event.target.value;
  }

  @action
  updateAuthorUsername(event) {
    this.authorUsername = event.target.value;
  }

  @action
  updateAuthorshipMode(event) {
    this.authorshipMode = event.target.value;
  }

  @action
  updateUnmappedAuthorPolicy(event) {
    this.unmappedAuthorPolicy = event.target.value;
  }

  @action
  updateSourceMapping(sourceAuthor, event) {
    this.sourceMappings = {
      ...this.sourceMappings,
      [sourceAuthor.id]: event.target.value,
    };
  }

  @action
  updateOrigins(event) {
    this.origins = event.target.value;
  }

  @action
  updateLanes(event) {
    this.lanes = event.target.value;
  }

  @action
  updateDefaultCategory(event) {
    this.defaultCategoryId = event.target.value;
  }

  @action
  updateToDiscourse(event) {
    this.toDiscourse = event.target.checked;
  }

  @action
  updateFromDiscourse(event) {
    this.fromDiscourse = event.target.checked;
  }

  @action
  updateGenerateTopicToc(event) {
    this.generateTopicToc = event.target.checked;
  }

  @action
  async saveConnection(event) {
    event.preventDefault();
    const directions = [];
    if (this.toDiscourse) {
      directions.push("to_discourse");
    }
    if (this.fromDiscourse) {
      directions.push("from_discourse");
    }
    this.feedback = "";
    this.saving = true;
    try {
      const editing = this.args.connection?.id;
      const url = editing
        ? `/discussion-bridge/admin/content-connections/${editing}.json`
        : "/discussion-bridge/admin/content-connections.json";
      const result = await ajax(url, {
        type: editing ? "PUT" : "POST",
        data: {
          content_connection:
            this.args.section === "authors"
              ? {
                  author_username: this.authorUsername,
                  authorship_mode: this.authorshipMode,
                  unmapped_author_policy: this.unmappedAuthorPolicy,
                }
              : {
                  name: this.name,
                  platform: this.platform,
                  author_username: this.authorUsername,
                  generate_topic_toc: this.generateTopicToc,
                  allowed_origins: this.lines(this.origins),
                  allowed_directions: directions,
                  allowed_lanes: this.lines(this.lanes),
                  default_category_id: this.defaultCategoryId,
                },
        },
      });
      if (result.secret) {
        this.args.onIssuedSecret?.(result.secret, result.content_connection.public_id);
        this.resetForm();
      } else {
        this.applyConnection(result.content_connection);
        this.feedback = i18n("discussion_bridge.admin.connection_saved");
      }
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  applyConnection(connection) {
    this.name = connection.name;
    this.platform = connection.platform;
    this.authorUsername = connection.author_override
      ? connection.author_username
      : "";
    this.authorshipMode = connection.authorship_mode;
    this.unmappedAuthorPolicy = connection.unmapped_author_policy;
    this.sourceMappings = Object.fromEntries(
      connection.source_authors.map((author) => [
        author.id,
        author.discourse_username ?? "",
      ])
    );
    this.origins = connection.allowed_origins.join("\n");
    this.lanes = connection.allowed_lanes.join("\n");
    this.defaultCategoryId = connection.default_category_id?.toString() ?? "";
    this.toDiscourse = connection.allowed_directions.includes("to_discourse");
    this.fromDiscourse =
      connection.allowed_directions.includes("from_discourse");
    this.generateTopicToc = connection.generate_topic_toc;
  }

  @action
  async saveAuthorMapping(sourceAuthor) {
    try {
      await ajax(
        `/discussion-bridge/admin/content-connections/${this.args.connection.id}/authors/${sourceAuthor.id}.json`,
        {
          type: "PUT",
          data: {
            source_author: {
              discourse_username: this.sourceMappings[sourceAuthor.id] ?? "",
            },
          },
        }
      );
      this.feedback = i18n("discussion_bridge.admin.author_mapping_saved");
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  lines(value) {
    return value
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .filter(Boolean);
  }

  resetForm() {
    this.args.connection.id = null;
    this.name = "";
    this.platform = "";
    this.authorUsername = "";
    this.authorshipMode = "fixed";
    this.unmappedAuthorPolicy = "fallback";
    this.sourceMappings = {};
    this.origins = "";
    this.lanes = "";
    this.defaultCategoryId = "";
    this.toDiscourse = true;
    this.fromDiscourse = true;
    this.generateTopicToc = false;
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  <template>
    <form
      class="discussion-bridge-add-connection"
      {{on "submit" this.saveConnection}}
    >
      {{#unless @connection}}
        <h3>{{i18n "discussion_bridge.admin.add_connection"}}</h3>
      {{/unless}}
      {{#unless (eq @section "authors")}}
        <label>{{i18n "discussion_bridge.admin.connection_name"}}<input
            required
            value={{this.name}}
            {{on "input" this.updateName}}
          /></label>
        <label>{{i18n "discussion_bridge.admin.platform"}}
          <select required {{on "change" this.updatePlatform}}>
            <option selected={{eq this.platform ""}} value="">{{i18n
                "discussion_bridge.admin.select_platform"
              }}</option>
            {{#each @model.platforms as |platform|}}<option
                selected={{eq platform this.platform}}
                value={{platform}}
              >{{this.displayToken platform}}</option>{{/each}}
          </select>
        </label>
        <label>{{i18n "discussion_bridge.admin.topic_author"}}<input
            placeholder={{i18n
              "discussion_bridge.admin.topic_author_default"
            }}
            value={{this.authorUsername}}
            {{on "input" this.updateAuthorUsername}}
          /></label>
        <label>{{i18n "discussion_bridge.admin.allowed_origins"}}<textarea
            required
            value={{this.origins}}
            {{on "input" this.updateOrigins}}
          ></textarea></label>
        <label>{{i18n "discussion_bridge.admin.companion_topic_category"}}
          <select {{on "change" this.updateDefaultCategory}}>
            <option selected={{eq this.defaultCategoryId ""}} value="">
              {{#if @model.fallback_category.name}}
                {{i18n
                  "discussion_bridge.admin.use_forum_fallback_category"
                  category=@model.fallback_category.name
                }}
              {{else}}
                {{i18n "discussion_bridge.admin.forum_fallback_unavailable"}}
              {{/if}}
            </option>
            {{#each @model.categories as |category|}}
              <option
                selected={{eq this.defaultCategoryId category.id_string}}
                value={{category.id}}
              >{{category.name}}</option>
            {{/each}}
          </select>
          <small>{{i18n
              "discussion_bridge.admin.companion_topic_category_description"
            }}</small>
        </label>
        <label>{{i18n "discussion_bridge.admin.allowed_lanes"}}<textarea
            value={{this.lanes}}
            {{on "input" this.updateLanes}}
          ></textarea></label>
        <fieldset class="discussion-bridge-direction-options">
          <legend>{{i18n
              "discussion_bridge.admin.allowed_directions"
            }}</legend>
          <label class="discussion-bridge-direction-option"><input
              checked={{this.toDiscourse}}
              type="checkbox"
              {{on "change" this.updateToDiscourse}}
            /><span>{{i18n
                "discussion_bridge.admin.to_discourse"
              }}</span></label>
          <label class="discussion-bridge-direction-option"><input
              checked={{this.fromDiscourse}}
              type="checkbox"
              {{on "change" this.updateFromDiscourse}}
            /><span>{{i18n
                "discussion_bridge.admin.from_discourse"
              }}</span></label>
        </fieldset>
        <label class="discussion-bridge-checkbox-setting">
          <input
            aria-label={{i18n "discussion_bridge.admin.generate_topic_toc"}}
            checked={{this.generateTopicToc}}
            type="checkbox"
            {{on "change" this.updateGenerateTopicToc}}
          />
          <span><strong>{{i18n
                "discussion_bridge.admin.generate_topic_toc"
              }}</strong><small>{{i18n
                "discussion_bridge.admin.generate_topic_toc_description"
              }}</small></span>
        </label>
      {{else}}
        <section class="discussion-bridge-authors-panel">
          <p>{{i18n "discussion_bridge.admin.authors_description"}}</p>
          <label>{{i18n "discussion_bridge.admin.authorship_mode"}}
            <select {{on "change" this.updateAuthorshipMode}}>
              <option
                selected={{eq this.authorshipMode "fixed"}}
                value="fixed"
              >{{i18n "discussion_bridge.admin.authorship_fixed"}}</option>
              <option
                selected={{eq this.authorshipMode "mapped"}}
                value="mapped"
              >{{i18n "discussion_bridge.admin.authorship_mapped"}}</option>
            </select>
          </label>
          <label>{{i18n "discussion_bridge.admin.fallback_author"}}<input
              placeholder={{i18n
                "discussion_bridge.admin.topic_author_default"
              }}
              value={{this.authorUsername}}
              {{on "input" this.updateAuthorUsername}}
            /></label>
          <label>{{i18n "discussion_bridge.admin.unmapped_author_policy"}}
            <select {{on "change" this.updateUnmappedAuthorPolicy}}>
              <option
                selected={{eq this.unmappedAuthorPolicy "fallback"}}
                value="fallback"
              >{{i18n "discussion_bridge.admin.unmapped_fallback"}}</option>
              <option
                selected={{eq this.unmappedAuthorPolicy "hold"}}
                value="hold"
              >{{i18n "discussion_bridge.admin.unmapped_hold"}}</option>
            </select>
          </label>

          <table class="discussion-bridge-authors-table">
            <thead><tr><th>{{i18n
                    "discussion_bridge.admin.platform_author"
                  }}</th><th>{{i18n
                    "discussion_bridge.admin.profile"
                  }}</th><th>{{i18n
                    "discussion_bridge.admin.discourse_author"
                  }}</th><th></th></tr></thead>
            <tbody>
              {{#each @connection.source_authors as |sourceAuthor|}}
                <tr>
                  <td><strong>{{sourceAuthor.display_name}}</strong><br
                    /><code>{{sourceAuthor.source_author_id}}</code></td>
                  <td>{{#if sourceAuthor.profile_url}}<a
                        href={{sourceAuthor.profile_url}}
                        rel="noopener noreferrer"
                        target="_blank"
                      >{{sourceAuthor.profile_url}}</a>{{else}}—{{/if}}</td>
                  <td><input
                      placeholder={{i18n
                        "discussion_bridge.admin.unmapped"
                      }}
                      value={{get this.sourceMappings sourceAuthor.id}}
                      {{on
                        "input"
                        (fn this.updateSourceMapping sourceAuthor)
                      }}
                    /></td>
                  <td><DButton
                      @action={{this.saveAuthorMapping}}
                      @actionParam={{sourceAuthor}}
                      @label="discussion_bridge.admin.save_mapping"
                    /></td>
                </tr>
              {{else}}
                <tr><td colspan="4">{{i18n
                      "discussion_bridge.admin.no_source_authors"
                    }}</td></tr>
              {{/each}}
            </tbody>
          </table>
        </section>
      {{/unless}}
      <DButton
        class="btn-primary"
        @disabled={{this.saving}}
        @label={{if
          @connection
          "discussion_bridge.admin.save_connection"
          "discussion_bridge.admin.add_connection"
        }}
        @type="submit"
      />
      {{#if @connection}}
        <LinkTo
          class="btn btn-default"
          @route="adminPlugins.show.discussion-bridge-connections"
          @query={{hash return_to=(concat @connection.id)}}
        >{{i18n "discussion_bridge.admin.cancel"}}</LinkTo>
      {{/if}}
      {{#if this.feedback}}<p role="status">{{this.feedback}}</p>{{/if}}
    </form>
  </template>
}
