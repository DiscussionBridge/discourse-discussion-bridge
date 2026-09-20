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

export default class DiscussionBridgePublishing extends Component {
  @service router;

  @tracked topicId = "";
  @tracked connectionId = "";
  @tracked externalId = "";
  @tracked canonicalUrl = "";
  @tracked canonicalUrlIsSuggested = true;
  @tracked lane = "";
  @tracked nativeMaterialization = false;
  @tracked notice = "";
  @tracked noticeContext = "";
  @tracked createdRecord = null;
  @tracked working = false;
  @tracked editingRecord = null;
  @tracked migrationMode = false;
  @tracked legacyNativeConfirmed = false;
  @tracked legacyPlatformContentId = "";
  @tracked correctedCanonicalUrl = "";
  @tracked correctedPresentationUrls = {};
  @tracked migratedNativeResourceIds = {};

  @action
  updateTopicId(event) {
    this.topicId = event.target.value;
  }

  @action
  updateConnectionId(event) {
    this.connectionId = event.target.value ? Number(event.target.value) : "";
    const connection = this.selectedConnection;
    this.lane =
      connection?.allowed_lanes?.length === 1
        ? connection.allowed_lanes[0]
        : "";
    if (this.canonicalUrlIsSuggested || !this.canonicalUrl) {
      this.canonicalUrl = this.suggestedCanonicalUrl;
      this.canonicalUrlIsSuggested = true;
    }
  }

  @action
  updateLane(event) {
    this.lane = event.target.value;
  }

  @action
  updateExternalId(event) {
    this.externalId = event.target.value;
    if (this.canonicalUrlIsSuggested || !this.canonicalUrl) {
      this.canonicalUrl = this.suggestedCanonicalUrl;
      this.canonicalUrlIsSuggested = true;
    }
  }

  @action
  updateCanonicalUrl(event) {
    this.canonicalUrl = event.target.value;
    this.canonicalUrlIsSuggested = false;
  }

  @action
  updateNativeMaterialization(event) {
    this.nativeMaterialization = event.target.checked;
  }

  @action
  beginPresentationCorrection(record) {
    this.editingRecord = record;
    this.migrationMode = false;
    this.correctedCanonicalUrl = this.presentationUrl(record);
    this.notice = "";
    this.noticeContext = "";
  }

  @action
  beginPresentationMigration(record) {
    this.editingRecord = record;
    this.migrationMode = true;
    this.legacyNativeConfirmed = false;
    this.legacyPlatformContentId = "";
    this.correctedCanonicalUrl = "";
    this.notice = "";
    this.noticeContext = "";
  }

  @action
  cancelPresentationCorrection() {
    this.editingRecord = null;
    this.migrationMode = false;
    this.legacyNativeConfirmed = false;
    this.legacyPlatformContentId = "";
    this.correctedCanonicalUrl = "";
  }

  @action
  updateCorrectedCanonicalUrl(event) {
    this.correctedCanonicalUrl = event.target.value;
  }

  @action
  updateLegacyNativeConfirmed(event) {
    this.legacyNativeConfirmed = event.target.checked;
  }

  @action
  updateLegacyPlatformContentId(event) {
    this.legacyPlatformContentId = event.target.value;
  }

  @action
  async correctPresentation(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      const result = await ajax(
        `/discussion-bridge/v1/publisher/publications/${this.editingRecord.resource_id}/presentation.json`,
        {
          type: "PUT",
          data: { publication: { canonical_url: this.correctedCanonicalUrl } },
        }
      );
      this.createdRecord = result;
      this.correctedPresentationUrls = {
        ...this.correctedPresentationUrls,
        [result.resource_id]: result.canonical_url,
      };
      this.notice = i18n(
        "discussion_bridge.admin.publisher_presentation_corrected"
      );
      this.noticeContext = "correction";
      this.cancelPresentationCorrection();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  @action
  async migratePresentation(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      const result = await ajax(
        `/discussion-bridge/v1/publisher/publications/${this.editingRecord.resource_id}/migrate-url.json`,
        {
          type: "PUT",
          data: {
            migration: {
              old_url: this.presentationUrl(this.editingRecord),
              new_url: this.correctedCanonicalUrl,
              legacy_native_confirmation: this.legacyNativeConfirmed,
              platform_content_id: this.legacyPlatformContentId,
            },
          },
        }
      );
      this.createdRecord = result;
      this.correctedPresentationUrls = {
        ...this.correctedPresentationUrls,
        [result.resource_id]: result.canonical_url,
      };
      if (result.native_materialization) {
        this.migratedNativeResourceIds = {
          ...this.migratedNativeResourceIds,
          [result.resource_id]: true,
        };
      }
      this.notice = i18n("discussion_bridge.admin.publisher_presentation_migrated");
      this.noticeContext = "correction";
      this.cancelPresentationCorrection();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  get selectedConnection() {
    return this.args.model.connections.find(
      (connection) => String(connection.id) === String(this.connectionId)
    );
  }

  get queueAttention() {
    const work = this.args.model.metrics.publication_work || {};
    return (work.attention || 0) + (work.failed || 0);
  }

  get selectedLanes() {
    return this.selectedConnection?.allowed_lanes || [];
  }

  get suggestedCanonicalUrl() {
    const connection = this.selectedConnection;
    const slug = this.externalId.trim().toLowerCase();
    if (
      !connection?.allowed_origins?.length ||
      !/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(slug)
    ) {
      return "";
    }
    try {
      const sourcePath = connection.include_source_in_published_url
        ? `${connection.publication_source_path}/`
        : "";
      return new URL(`/${sourcePath}${slug}/`, connection.allowed_origins[0])
        .href;
    } catch {
      return "";
    }
  }

  @action
  async retryPublicationWork(item) {
    this.working = true;
    this.notice = "";
    try {
      await ajax(
        `/discussion-bridge/admin/publishing/work/${item.id}/retry.json`,
        { type: "POST" }
      );
      this.notice = i18n("discussion_bridge.admin.publication_retry_queued");
      await this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  @action
  async publishTopic(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    this.noticeContext = "";
    try {
      const result = await ajax(
        `/discussion-bridge/v1/publisher/topics/${this.topicId}/publish.json`,
        {
          type: "POST",
          data: {
            publication: {
              content_connection_id: this.connectionId,
              external_id: this.externalId,
              canonical_url: this.canonicalUrl,
              lane: this.lane || null,
              native_materialization: this.nativeMaterialization,
            },
          },
        }
      );
      this.createdRecord = result;
      this.notice = this.publicationOutcomeLabel(result);
      this.noticeContext = "publication";
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  publicationOutcomeLabel(result) {
    const platform = [
      "astro",
      "ghost",
      "hugo",
      "statamic",
      "wordpress",
    ].includes(result.platform)
      ? `_${result.platform}`
      : "";
    const outcome = result.outcome === "created" ? "created" : "resolved";

    return i18n(`discussion_bridge.admin.publisher_${outcome}${platform}`);
  }

  @action
  presentationUrl(record) {
    return (
      this.correctedPresentationUrls[record.resource_id] || record.canonical_url
    );
  }

  @action
  nativePublication(record) {
    return (
      this.migratedNativeResourceIds[record.resource_id] ||
      record.native_materialization
    );
  }

  <template>
    <section class="discussion-bridge-publishing">
      <header class="discussion-bridge-publishing__hero">
        <div><span aria-hidden="true">DB</span><div><h2>{{i18n
                "discussion_bridge.admin.publishing_nav"
              }}</h2><p>{{i18n
                "discussion_bridge.admin.publishing_description"
              }}</p></div></div>
        <strong data-ready={{@model.product.ready}}>{{if
            @model.product.ready
            (i18n "discussion_bridge.admin.publisher_ready")
            (i18n "discussion_bridge.admin.needs_attention")
          }}</strong>
      </header>

      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.publishing_nav"}}
        @descriptionLabel={{@model.product.version}}
      />

      <div class="discussion-bridge-publishing__metrics">
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_published_topics"
            }}</span><strong
          >{{@model.metrics.published_topics}}</strong></article>
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_presentations"
            }}</span><strong>{{@model.metrics.presentations}}</strong></article>
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_connected_platforms"
            }}</span><strong
          >{{@model.metrics.connected_platforms}}</strong></article>
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_queue_attention"
            }}</span><strong>{{this.queueAttention}}</strong></article>
      </div>

      {{#if @model.product.blockers.length}}
        <section class="discussion-bridge-publishing__connection">
          <h3>{{i18n
              "discussion_bridge.admin.publisher_configuration_blockers"
            }}</h3>
          <ul>{{#each @model.product.blockers as |blocker|}}<li><code
                >{{blocker}}</code></li>{{/each}}</ul>
        </section>
      {{/if}}

      <div class="discussion-bridge-publishing__actions">
        <form {{on "submit" this.publishTopic}}>
          <h3>{{i18n "discussion_bridge.admin.publisher_publish_title"}}</h3>
          <p>{{i18n
              "discussion_bridge.admin.publisher_publish_description"
            }}</p>
          <label class="discussion-bridge-publishing__topic-id">{{i18n
              "discussion_bridge.admin.publisher_local_topic_id"
            }}<input
              required
              min="1"
              max="999999999999"
              inputmode="numeric"
              type="number"
              value={{this.topicId}}
              {{on "input" this.updateTopicId}}
            /></label>
          <label>{{i18n "discussion_bridge.admin.publisher_connection"}}
            <select required {{on "change" this.updateConnectionId}}>
              <option
                value=""
                selected={{eq this.connectionId ""}}
                disabled
              >{{i18n "discussion_bridge.admin.select_connection"}}</option>
              {{#each @model.connections as |connection|}}<option
                  value={{connection.id}}
                  selected={{eq connection.id this.connectionId}}
                >{{connection.name}}
                  ·
                  {{this.displayToken connection.platform}}</option>{{/each}}
            </select>
          </label>
          {{#if this.selectedLanes.length}}
            <label>{{i18n "discussion_bridge.admin.publisher_lane"}}
              <select required {{on "change" this.updateLane}}>
                <option value="" selected={{eq this.lane ""}} disabled>{{i18n
                    "discussion_bridge.admin.select_category_route"
                  }}</option>
                {{#each this.selectedLanes as |lane|}}<option
                    value={{lane}}
                    selected={{eq lane this.lane}}
                  >{{lane}}</option>{{/each}}
              </select>
              <small>{{i18n
                  "discussion_bridge.admin.publisher_lane_description"
                }}</small>
            </label>
          {{/if}}
          <label>{{i18n "discussion_bridge.admin.external_id"}}<input
              required
              value={{this.externalId}}
              {{on "input" this.updateExternalId}}
            /></label>
          <label>{{i18n "discussion_bridge.admin.presentation_url"}}<input
              required
              type="url"
              value={{this.canonicalUrl}}
              {{on "input" this.updateCanonicalUrl}}
            /><small>{{i18n
                "discussion_bridge.admin.presentation_url_suggestion"
              }}</small></label>
          <label class="discussion-bridge-publishing__checkbox"><input
              type="checkbox"
              checked={{this.nativeMaterialization}}
              {{on "change" this.updateNativeMaterialization}}
            /><span>{{i18n
                "discussion_bridge.admin.publisher_native_materialization"
              }}</span></label>
          <DButton
            @type="submit"
            @label="discussion_bridge.admin.publisher_publish"
            @disabled={{this.working}}
            class="btn-primary"
          />
          {{#if (eq this.noticeContext "publication")}}
            <p
              class="discussion-bridge-publishing__notice"
              role="status"
            ><strong>{{this.notice}}</strong>{{#if this.createdRecord}}
                ·
                <a href={{this.createdRecord.topic_url}}>Open topic
                  {{this.createdRecord.topic_id}}</a>{{/if}}</p>
          {{/if}}
        </form>
      </div>

      <section class="discussion-bridge-publishing__recent">
        <h3>{{i18n "discussion_bridge.admin.publisher_recent_activity"}}</h3>
        <p><a href="/admin/plugins/discourse-discussion-bridge/bridge-records">{{i18n
              "discussion_bridge.admin.publisher_all_records"
            }}</a></p>
        {{#if (eq this.noticeContext "correction")}}
          <p class="discussion-bridge-publishing__notice" role="status"><strong
            >{{this.notice}}</strong>{{#if this.createdRecord}}
              ·
              <a href={{this.createdRecord.topic_url}}>Open topic
                {{this.createdRecord.topic_id}}</a>{{/if}}</p>
        {{/if}}
        <table><thead><tr><th>{{i18n
                  "discussion_bridge.admin.publisher_local_topic"
                }}</th><th>{{i18n "discussion_bridge.admin.platform"}}</th><th
              >{{i18n "discussion_bridge.admin.presentation"}}</th><th>{{i18n
                  "discussion_bridge.admin.state"
                }}</th><th>{{i18n
                  "discussion_bridge.admin.actions"
                }}</th></tr></thead>
          <tbody>{{#each @model.recent_records as |record|}}
              <tr><td><a href={{record.topic_url}}>Topic {{record.topic_id}} · {{record.title}}</a><small
                  ><code>{{record.resource_id}}</code></small></td><td
                >{{this.displayToken record.platform}}</td><td><a
                    href={{this.presentationUrl record}}
                  >{{record.connection_name}}</a></td><td><span
                    class="discussion-bridge-status"
                    data-state={{record.delivery_state}}
                  >{{this.displayToken record.delivery_state}}</span>{{#if
                    record.delivery_reason
                  }}<small>{{this.displayToken record.delivery_reason}}</small>{{/if}}</td><td>
                  {{#if (this.nativePublication record)}}
                    <DButton
                      @label="discussion_bridge.admin.publisher_migrate_presentation"
                      @action={{this.beginPresentationMigration}}
                      @actionParam={{record}}
                    />
                  {{else}}
                    <DButton
                      @label="discussion_bridge.admin.publisher_edit_presentation"
                      @action={{this.beginPresentationCorrection}}
                      @actionParam={{record}}
                    />
                    <DButton
                      @label="discussion_bridge.admin.publisher_migrate_legacy_presentation"
                      @action={{this.beginPresentationMigration}}
                      @actionParam={{record}}
                    />
                  {{/if}}
                </td></tr>
              {{#if this.editingRecord}}
                {{#if (eq record.resource_id this.editingRecord.resource_id)}}
                  <tr class="discussion-bridge-publishing__correction-row"><td
                      colspan="5"
                    >
                      {{#if this.migrationMode}}
                        <form
                          class="discussion-bridge-publishing__correction"
                          {{on "submit" this.migratePresentation}}
                        >
                          <h4>{{i18n "discussion_bridge.admin.publisher_migrate_presentation"}}</h4>
                          <p>{{i18n "discussion_bridge.admin.publisher_migrate_presentation_description"}}</p>
                          {{#unless (this.nativePublication record)}}
                            <p>{{i18n "discussion_bridge.admin.publisher_legacy_native_description"}}</p>
                            <p><strong>{{i18n "discussion_bridge.admin.publisher_platform_content_id"}}</strong>
                              <code>{{record.external_id}}</code></p>
                            <label>{{i18n "discussion_bridge.admin.publisher_confirm_platform_content_id"}}<input
                                required
                                type="text"
                                value={{this.legacyPlatformContentId}}
                                {{on "input" this.updateLegacyPlatformContentId}}
                              /></label>
                            <label><input
                                required
                                type="checkbox"
                                checked={{this.legacyNativeConfirmed}}
                                {{on "change" this.updateLegacyNativeConfirmed}}
                              />{{i18n "discussion_bridge.admin.publisher_confirm_legacy_native"}}</label>
                          {{/unless}}
                          <p><strong>{{i18n "discussion_bridge.admin.publisher_old_presentation_url"}}</strong>
                            <code>{{this.presentationUrl record}}</code></p>
                          <label>{{i18n "discussion_bridge.admin.publisher_new_presentation_url"}}<input
                              required
                              type="url"
                              value={{this.correctedCanonicalUrl}}
                              {{on "input" this.updateCorrectedCanonicalUrl}}
                            /></label>
                          <DButton
                            @type="submit"
                            @label="discussion_bridge.admin.publisher_verify_and_migrate"
                            @disabled={{this.working}}
                            class="btn-primary"
                          />
                          <DButton
                            @label="discussion_bridge.admin.cancel"
                            @action={{this.cancelPresentationCorrection}}
                            @disabled={{this.working}}
                          />
                        </form>
                      {{else}}
                        <form
                          class="discussion-bridge-publishing__correction"
                          {{on "submit" this.correctPresentation}}
                        >
                        <h4>{{i18n
                            "discussion_bridge.admin.publisher_edit_presentation"
                          }}</h4>
                        <p>{{i18n
                            "discussion_bridge.admin.publisher_edit_presentation_description"
                          }}</p>
                        <label>{{i18n
                            "discussion_bridge.admin.presentation_url"
                          }}<input
                            required
                            type="url"
                            value={{this.correctedCanonicalUrl}}
                            {{on "input" this.updateCorrectedCanonicalUrl}}
                          /></label>
                        <DButton
                          @type="submit"
                          @label="discussion_bridge.admin.publisher_save_presentation"
                          @disabled={{this.working}}
                          class="btn-primary"
                        />
                        <DButton
                          @label="discussion_bridge.admin.cancel"
                          @action={{this.cancelPresentationCorrection}}
                          @disabled={{this.working}}
                        />
                        </form>
                      {{/if}}
                    </td></tr>
                {{/if}}
              {{/if}}
            {{else}}<tr><td colspan="5">{{i18n
                    "discussion_bridge.admin.publisher_no_activity"
                  }}</td></tr>{{/each}}</tbody>
        </table>
      </section>

      <section class="discussion-bridge-publishing__recent">
        <h3>{{i18n "discussion_bridge.admin.publication_queue"}}</h3>
        <p>{{i18n "discussion_bridge.admin.publication_queue_description"}}</p>
        <table>
          <thead><tr><th>{{i18n "discussion_bridge.admin.publisher_local_topic"}}</th><th>{{i18n "discussion_bridge.admin.connection"}}</th><th>{{i18n "discussion_bridge.admin.action"}}</th><th>{{i18n "discussion_bridge.admin.status"}}</th><th>{{i18n "discussion_bridge.admin.reason"}}</th><th>{{i18n "discussion_bridge.admin.actions"}}</th></tr></thead>
          <tbody>
            {{#each @model.publication_work as |item|}}
              <tr>
                <td><a href={{item.topic_url}}>Topic {{item.topic_id}} · {{item.title}}</a></td>
                <td>{{item.connection_name}} · {{this.displayToken item.platform}}</td>
                <td>{{this.displayToken item.action}}</td>
                <td><span class="discussion-bridge-status" data-state={{item.state}}>{{this.displayToken item.state}}</span></td>
                <td>{{this.displayToken item.reason}}{{#if item.last_error_detail}}<small>{{item.last_error_detail}}</small>{{/if}}</td>
                <td>{{#if (eq item.state "failed")}}<DButton
                    @label="discussion_bridge.admin.retry_publication"
                    @action={{fn this.retryPublicationWork item}}
                    @disabled={{this.working}}
                    class="btn-small"
                  />{{/if}}</td>
              </tr>
            {{else}}
              <tr><td colspan="6">{{i18n "discussion_bridge.admin.publication_queue_empty"}}</td></tr>
            {{/each}}
          </tbody>
        </table>
      </section>
    </section>
  </template>
}
