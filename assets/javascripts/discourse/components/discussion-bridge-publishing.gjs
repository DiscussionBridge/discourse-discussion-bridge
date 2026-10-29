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

export default class DiscussionBridgePublishing extends Component {
  @service router;

  @tracked topicId = "";

  @tracked connectionId = "";
  @tracked externalId = "";
  @tracked canonicalUrl = "";
  @tracked lane = "";
  @tracked presentationMode = "";
  @tracked presentationModeSelected = false;
  @tracked notice = "";
  @tracked noticeContext = "";
  @tracked createdRecord = null;
  @tracked working = false;
  @tracked editingRecord = null;
  @tracked correctedCanonicalUrl = "";
  @tracked correctedPresentationUrls = {};

  get selectedConnection() {
    return this.args.model.connections.find(
      (connection) => String(connection.id) === String(this.connectionId)
    );
  }

  get selectedLanes() {
    return this.selectedConnection?.allowed_lanes || [];
  }

  publicationStatus(value) {
    return i18n(`discussion_bridge.admin.cms.delivery_states.${value}`);
  }

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
  }

  @action
  updateLane(event) {
    this.lane = event.target.value;
  }

  @action
  updateExternalId(event) {
    this.externalId = event.target.value;
  }

  @action
  updateCanonicalUrl(event) {
    this.canonicalUrl = event.target.value;
  }

  @action
  updatePresentationMode(event) {
    this.presentationMode = event.target.value;
    this.presentationModeSelected = true;
  }

  @action
  beginPresentationCorrection(record) {
    this.editingRecord = record;
    this.correctedCanonicalUrl = this.presentationUrl(record);
    this.notice = "";
    this.noticeContext = "";
  }

  @action
  cancelPresentationCorrection() {
    this.editingRecord = null;
    this.correctedCanonicalUrl = "";
  }

  @action
  updateCorrectedCanonicalUrl(event) {
    this.correctedCanonicalUrl = event.target.value;
  }

  @action
  async correctPresentation(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    try {
      const result = await ajax(
        `/admin/publishing/publications/${this.editingRecord.resource_id}/presentation.json`,
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
        result.outcome === "presentation_pending"
          ? "discussion_bridge.admin.publisher_presentation_pending"
          : "discussion_bridge.admin.publisher_presentation_unchanged"
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
  async publishTopic(event) {
    event.preventDefault();
    this.working = true;
    this.notice = "";
    this.noticeContext = "";
    try {
      const result = await ajax(
        `/admin/publishing/topics/${this.topicId}/publish.json`,
        {
          type: "POST",
          contentType: "application/json",
          data: JSON.stringify({
            publication: {
              content_connection_id: this.connectionId,
              external_id: this.externalId,
              canonical_url: this.canonicalUrl,
              lane: this.lane || null,
              ...(this.presentationModeSelected
                ? { presentation_mode: this.presentationMode || null }
                : {}),
            },
          }),
        }
      );
      this.createdRecord = result;
      this.notice = i18n(
        result.outcome === "created"
          ? "discussion_bridge.admin.publisher_created"
          : "discussion_bridge.admin.publisher_resolved"
      );
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

  @action
  presentationUrl(record) {
    return (
      this.correctedPresentationUrls[record.resource_id] || record.canonical_url
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
        @descriptionLabel={{@model.product.version}}
        @titleLabel={{i18n "discussion_bridge.admin.publishing_nav"}}
      />

      <div class="discussion-bridge-publishing__metrics">
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_tracked_topics"
            }}</span><strong
          >{{@model.metrics.tracked_topics}}</strong></article>
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_presentations"
            }}</span><strong>{{@model.metrics.presentations}}</strong></article>
        <article><span>{{i18n
              "discussion_bridge.admin.publisher_connected_platforms"
            }}</span><strong
          >{{@model.metrics.connected_platforms}}</strong></article>
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
              min="1"
              required
              type="number"
              value={{this.topicId}}
              {{on "input" this.updateTopicId}}
            /></label>
          <label>{{i18n "discussion_bridge.admin.publisher_connection"}}
            <select required {{on "change" this.updateConnectionId}}>
              <option value="">—</option>
              {{#each @model.connections as |connection|}}<option
                  selected={{eq connection.id this.connectionId}}
                  value={{connection.id}}
                >{{connection.name}}
                  ·
                  {{this.displayToken connection.platform}}</option>{{/each}}
            </select>
          </label>
          {{#if this.selectedLanes.length}}
            <label>{{i18n "discussion_bridge.admin.publisher_lane"}}
              <select required {{on "change" this.updateLane}}>
                <option value="">—</option>
                {{#each this.selectedLanes as |lane|}}<option
                    selected={{eq lane this.lane}}
                    value={{lane}}
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
            /></label>

          <label>{{i18n "discussion_bridge.admin.publisher_presentation_mode"}}
            <select {{on "change" this.updatePresentationMode}}>
              <option selected={{eq this.presentationMode ""}} value="">{{i18n
                  "discussion_bridge.admin.publisher_destination_mode"
                }}</option>
              <option
                selected={{eq this.presentationMode "simple"}}
                value="simple"
              >Simple</option>
              <option
                selected={{eq this.presentationMode "full"}}
                value="full"
              >Full</option>
              <option
                selected={{eq this.presentationMode "interactive"}}
                value="interactive"
              >Interactive</option>
            </select>
          </label>
          <DButton
            class="btn-primary"
            @disabled={{this.working}}
            @label="discussion_bridge.admin.publisher_publish"
            @type="submit"
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
        {{#if (eq this.noticeContext "correction")}}
          <p class="discussion-bridge-publishing__notice" role="status"><strong
            >{{this.notice}}</strong>{{#if this.createdRecord}}
              ·
              <a href={{this.createdRecord.topic_url}}>Open topic
                {{this.createdRecord.topic_id}}</a>{{/if}}</p>
        {{/if}}
        {{#if this.createdRecord.presentation_move_intent}}
          <p>{{i18n
              "discussion_bridge.admin.publisher_presentation_requested"
            }}:
            <a
              href={{this.createdRecord.presentation_move_intent.requested_url}}
            >{{this.createdRecord.presentation_move_intent.requested_url}}</a>
            ·
            {{i18n
              "discussion_bridge.admin.publisher_presentation_move_state"
            }}:
            {{this.displayToken
              this.createdRecord.presentation_move_intent.state
            }}
            {{#if this.createdRecord.presentation_move_intent.attention_code}}
              <code
              >{{this.createdRecord.presentation_move_intent.attention_code}}</code>
            {{/if}}
          </p>
        {{/if}}
        <table><thead><tr><th>{{i18n
                  "discussion_bridge.admin.publisher_local_topic"
                }}</th><th>{{i18n "discussion_bridge.admin.platform"}}</th><th
              >{{i18n "discussion_bridge.admin.presentation"}}</th><th>{{i18n
                  "discussion_bridge.admin.publisher_status"
                }}</th><th>{{i18n
                  "discussion_bridge.admin.actions"
                }}</th></tr></thead>
          <tbody>{{#each @model.recent_records as |record|}}
              <tr><td><a href={{record.topic_url}}>{{record.title}}</a><small
                  ><code>{{record.resource_id}}</code></small></td><td
                >{{this.displayToken record.platform}}</td><td><a
                    href={{this.presentationUrl record}}
                  >{{record.connection_name}}</a></td><td><span>{{i18n
                      "discussion_bridge.admin.publisher_publication_status"
                    }}:
                    {{this.publicationStatus
                      record.publication_status
                    }}</span><small>{{i18n
                      "discussion_bridge.admin.publisher_discussion_status"
                    }}:
                    {{record.discussion_status}}</small>{{#if
                    record.delivery.attention_required
                  }}
                    <strong>{{i18n
                        "discussion_bridge.admin.cms.withdrawal_attention"
                      }}</strong>
                  {{/if}}</td><td><DButton
                    @action={{this.beginPresentationCorrection}}
                    @actionParam={{record}}
                    @label="discussion_bridge.admin.publisher_edit_presentation"
                  /></td></tr>
              {{#if this.editingRecord}}
                {{#if (eq record.resource_id this.editingRecord.resource_id)}}
                  <tr class="discussion-bridge-publishing__correction-row"><td
                      colspan="5"
                    >
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
                          class="btn-primary"
                          @disabled={{this.working}}
                          @label="discussion_bridge.admin.publisher_save_presentation"
                          @type="submit"
                        />
                        <DButton
                          @action={{this.cancelPresentationCorrection}}
                          @disabled={{this.working}}
                          @label="discussion_bridge.admin.cancel"
                        />
                      </form>
                    </td></tr>
                {{/if}}
              {{/if}}
            {{else}}<tr><td colspan="5">{{i18n
                    "discussion_bridge.admin.publisher_no_activity"
                  }}</td></tr>{{/each}}</tbody>
        </table>
      </section>
    </section>
  </template>
}
