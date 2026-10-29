import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

const PREFIX = "discussion_bridge.admin.cms";
const DEFAULT_LANE = "__discussionbridge_default_lane__";
const PROFILES = [
  "astro",
  "ghost",
  "hugo",
  "statamic_flat",
  "statamic_db",
  "statamic_ssg",
  "wordpress",
];
const MODES = ["simple", "full", "interactive"];

function emptyForm() {
  return {
    profile: "",
    destinationOrigin: "",
    publicationLane: "",
    nativeRevision: "",
    publicationKind: "",
    supportedPresentations: [],
    completeContent: "",
    enabled: false,
    sourceSelection: "",
    categoryIds: [],
    includeTopicIds: "",
    excludeTopicIds: "",
    includeUnlisted: false,
    presentationMode: "",
  };
}

export default class DiscussionBridgeCmsConfiguration extends Component {
  @tracked opened = false;
  @tracked loading = false;
  @tracked saving = false;
  @tracked loaded = false;
  @tracked configured = false;
  @tracked form = emptyForm();
  @tracked expectedPolicyRevision = null;
  @tracked authorIds = [];
  @tracked taxonomyIds = [];
  @tracked notice = "";
  @tracked revisionConflict = false;
  @tracked deliveries = [];
  @tracked loadingDelivery = false;
  @tracked deliveryAvailable = false;
  @tracked deliveryPage = 1;
  @tracked deliveryPages = 1;
  @tracked previewTopicId = "";
  @tracked loadingPreview = false;
  @tracked preview = null;
  @tracked catalogStates = { authors: {}, taxonomy: {} };
  @tracked attentionSelection = [];
  @tracked attentionBusy = false;
  @tracked attentionResults = [];

  attentionMutations = new Map();

  previewSequence = 0;
  catalogSequences = { authors: 0, taxonomy: 0 };

  loadSequence = 0;

  deliverySequence = 0;

  get catalogPanels() {
    return ["authors", "taxonomy"].map((kind) => ({
      kind,
      field: kind === "authors" ? "authorIds" : "taxonomyIds",
      label: i18n(
        `${PREFIX}.${kind === "authors" ? "selected_author_ids" : "selected_taxonomy_ids"}`
      ),
      selected: kind === "authors" ? this.authorIds : this.taxonomyIds,
      ...this.catalogStates[kind],
    }));
  }

  get previewDisabled() {
    return this.loadingPreview || !this.configured || !this.loaded || this.busy;
  }

  get deliveryPreviousDisabled() {
    return this.loadingDelivery || this.deliveryPage <= 1;
  }

  get deliveryNextDisabled() {
    return this.loadingDelivery || this.deliveryPage >= this.deliveryPages;
  }

  get selectedAttention() {
    return this.deliveries.filter(
      (row) =>
        row.attention_recovery?.can_check &&
        this.attentionSelection.includes(row.work?.work_id)
    );
  }

  get checkAttentionDisabled() {
    return this.attentionBusy || !this.selectedAttention.length;
  }

  get retryAttentionDisabled() {
    return (
      this.attentionBusy ||
      !this.selectedAttention.some(
        (row) =>
          !row.attention_recovery.settlement_required &&
          row.attention_recovery.inspection?.status === "ready"
      )
    );
  }

  get settleAttentionDisabled() {
    return (
      this.attentionBusy ||
      !this.selectedAttention.some(
        (row) =>
          row.attention_recovery.settlement_required &&
          row.attention_recovery.inspection?.status === "ready"
      )
    );
  }

  get profiles() {
    return PROFILES.filter((profile) =>
      this.args.connection.platform === "statamic"
        ? profile.startsWith("statamic_")
        : profile === this.args.connection.platform
    );
  }

  get profileChoices() {
    const choices = this.profiles.map((value) => ({
      value,
      label: i18n(`${PREFIX}.profiles.${value}`),
    }));
    if (this.form.profile && !this.profiles.includes(this.form.profile)) {
      choices.push({
        value: this.form.profile,
        label: i18n(`${PREFIX}.stored_choice`, { value: this.form.profile }),
      });
    }
    return choices;
  }

  get originChoices() {
    const choices = this.args.connection.allowed_origins
      .filter((origin) => origin.startsWith("https://"))
      .map((value) => ({ value, label: value }));
    if (
      this.form.destinationOrigin &&
      !choices.some((choice) => choice.value === this.form.destinationOrigin)
    ) {
      choices.push({
        value: this.form.destinationOrigin,
        label: i18n(`${PREFIX}.stored_choice`, {
          value: this.form.destinationOrigin,
        }),
      });
    }
    return choices;
  }

  get laneChoices() {
    const allowed = this.args.connection.allowed_lanes;
    const choices = allowed.length
      ? allowed.map((value) => ({ value, wireValue: value, label: value }))
      : [
          {
            value: DEFAULT_LANE,
            wireValue: "",
            label: i18n(`${PREFIX}.default_lane`),
          },
        ];
    if (
      this.form.publicationLane &&
      !choices.some((choice) => choice.value === this.form.publicationLane)
    ) {
      choices.push({
        value: this.form.publicationLane,
        wireValue:
          this.form.publicationLane === DEFAULT_LANE
            ? ""
            : this.form.publicationLane,
        label: i18n(`${PREFIX}.stored_choice`, {
          value:
            this.form.publicationLane === DEFAULT_LANE
              ? i18n(`${PREFIX}.default_lane`)
              : this.form.publicationLane,
        }),
      });
    }
    return choices;
  }

  get canPublishFrom() {
    return this.args.connection.allowed_directions.includes("from_discourse");
  }

  get enableDisabled() {
    return !this.canPublishFrom && !this.form.enabled;
  }

  get sourceCategories() {
    const categories = (this.args.categories || []).map((category) => ({
      id: category.id_string,
      label: category.read_restricted
        ? i18n(`${PREFIX}.restricted_category`, { name: category.name })
        : category.name,
    }));
    for (const id of this.form.categoryIds) {
      if (!categories.some((category) => category.id === id)) {
        categories.push({
          id,
          label: i18n(`${PREFIX}.stored_category`, { id }),
        });
      }
    }
    return categories;
  }

  get modes() {
    return MODES.map((value) => ({
      value,
      label: i18n(`${PREFIX}.modes.${value}`),
    }));
  }

  get chosenPresentationModes() {
    const choices = this.form.supportedPresentations.map((value) => ({
      value,
      label: i18n(`${PREFIX}.modes.${value}`),
    }));
    if (
      this.form.presentationMode &&
      !this.form.supportedPresentations.includes(this.form.presentationMode)
    ) {
      choices.push({
        value: this.form.presentationMode,
        label: i18n(`${PREFIX}.stored_choice`, {
          value: this.form.presentationMode,
        }),
      });
    }
    return choices;
  }

  get busy() {
    return this.loading || this.saving;
  }

  get saveDisabled() {
    return this.busy || !this.loaded || this.revisionConflict;
  }

  metadataSelected(field, id) {
    return this[field].includes(id);
  }

  previewFlag(value) {
    return i18n(`${PREFIX}.${value ? "preview_yes" : "preview_no"}`);
  }

  previewMode(value) {
    return i18n(`${PREFIX}.modes.${value}`);
  }

  @action
  reloadCatalog(kind) {
    return this.loadCatalog(kind);
  }

  @action
  nextCatalog(kind, cursor) {
    return this.loadCatalog(kind, cursor);
  }

  @action
  updateMetadata(field, id, event) {
    this[field] = event.target.checked
      ? [...this[field].filter((value) => value !== id), id]
      : this[field].filter((value) => value !== id);
  }

  @action
  removeMetadata(field, id) {
    this[field] = this[field].filter((value) => value !== id);
  }

  @action
  updatePreviewTopic(event) {
    this.previewTopicId = event.target.value;
    this.preview = null;
    this.previewSequence++;
    this.loadingPreview = false;
  }

  @action
  async loadPreview() {
    const sequence = ++this.previewSequence;
    this.loadingPreview = true;
    this.preview = null;
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-preview.json`,
        {
          data: { topic_id: this.previewTopicId.trim() },
        }
      );
      if (sequence === this.previewSequence && !this.isDestroying) {
        this.preview = result;
      }
    } catch (error) {
      if (sequence === this.previewSequence && !this.isDestroying) {
        popupAjaxError(error);
      }
    } finally {
      if (sequence === this.previewSequence && !this.isDestroying) {
        this.loadingPreview = false;
      }
    }
  }

  @action
  async loadCatalog(kind, cursor = null) {
    const sequence = ++this.catalogSequences[kind];
    this.catalogStates = {
      ...this.catalogStates,
      [kind]: { ...this.catalogStates[kind], loading: true, failed: false },
    };
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-catalog.json`,
        {
          data: cursor ? { kind, cursor } : { kind },
        }
      );
      if (sequence !== this.catalogSequences[kind] || this.isDestroying) {
        return;
      }
      const catalog = result.catalog;
      const availability = result.selection_availability;
      if (result.policy_revision !== this.expectedPolicyRevision) {
        this.revisionConflict = true;
        this.notice = i18n(`${PREFIX}.revision_conflict`);
      }
      const stale =
        catalog && catalog.catalog_revision !== result.current_catalog_revision;
      this.catalogStates = {
        ...this.catalogStates,
        [kind]: {
          loading: false,
          available: Boolean(catalog),
          items: (catalog?.items || []).map((entry) => ({
            ...entry,
            disabled: stale || !entry.available,
          })),
          catalogRevision: catalog?.catalog_revision,
          currentRevision: result.current_catalog_revision,
          nextCursor: catalog?.next_cursor,
          nextDisabled: !catalog?.next_cursor,
          stale,
          missing: availability.missing_ids[kind],
          unavailable: availability.unavailable_ids[kind],
          error: availability.catalog_errors[kind],
        },
      };
    } catch (error) {
      if (sequence === this.catalogSequences[kind] && !this.isDestroying) {
        this.catalogStates = {
          ...this.catalogStates,
          [kind]: { loading: false, failed: true, nextDisabled: true },
        };
        popupAjaxError(error);
      }
    }
  }

  deliveryStatus(value) {
    return value ? i18n(`${PREFIX}.delivery_states.${value}`) : "";
  }

  workAction(value) {
    return value ? i18n(`${PREFIX}.delivery_actions.${value}`) : "";
  }

  async loadDelivery(page = 1) {
    const sequence = ++this.deliverySequence;
    this.loadingDelivery = true;
    this.deliveryAvailable = false;
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-delivery.json?page=${page}`
      );
      if (sequence === this.deliverySequence && !this.isDestroying) {
        this.deliveries = result.deliveries;
        this.deliveryPage = result.page;
        this.deliveryPages = result.pages;
        this.deliveryAvailable = true;
      }
    } catch (error) {
      if (sequence === this.deliverySequence && !this.isDestroying) {
        popupAjaxError(error);
      }
    } finally {
      if (sequence === this.deliverySequence && !this.isDestroying) {
        this.loadingDelivery = false;
      }
    }
  }

  @action
  reloadDelivery() {
    return this.loadDelivery(this.deliveryPage);
  }

  @action
  attentionSelected(workId) {
    return this.attentionSelection.includes(workId);
  }

  inspectionStatus(value) {
    return i18n(`${PREFIX}.attention_states.${value}`);
  }

  @action
  selectAttention(workId, event) {
    this.attentionSelection = event.target.checked
      ? [...this.attentionSelection.filter((id) => id !== workId), workId]
      : this.attentionSelection.filter((id) => id !== workId);
  }

  async attentionAction(operation, selected) {
    if (this.attentionBusy || !selected.length) {
      return;
    }
    const key = JSON.stringify([operation, selected]);
    let body = this.attentionMutations.get(key);
    if (!body) {
      body = JSON.stringify({ mutation_id: crypto.randomUUID(), selected });
      this.attentionMutations.set(key, body);
    }
    this.attentionBusy = true;
    this.attentionResults = [];
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-attention/${operation}.json`,
        {
          type: "POST",
          contentType: "application/json",
          processData: false,
          ignoreUnsent: false,
          data: body,
        }
      );
      this.attentionMutations.delete(key);
      if (!this.isDestroying) {
        this.attentionResults = result.items;
        if (operation === "retry") {
          this.attentionSelection = [];
        }
        await this.loadDelivery(this.deliveryPage);
      }
    } catch (error) {
      if (!this.isDestroying) {
        popupAjaxError(error);
      }
    } finally {
      if (!this.isDestroying) {
        this.attentionBusy = false;
      }
    }
  }

  @action
  checkAttention(row) {
    const rows = row ? [row] : this.selectedAttention;
    return this.attentionAction(
      "check",
      rows.map((item) => ({
        work_id: item.work.work_id,
        mapping_revision: item.attention_recovery.mapping_revision,
      }))
    );
  }

  @action
  retryAttention(row, settle = false) {
    const rows = row
      ? [row]
      : this.selectedAttention.filter(
          (item) =>
            item.attention_recovery.settlement_required === settle &&
            item.attention_recovery.inspection?.status === "ready"
        );
    return this.attentionAction(
      "retry",
      rows.map((item) => ({
        inspection_id: item.attention_recovery.inspection.inspection_id,
        context_sha256: item.attention_recovery.inspection.context_sha256,
        settle_restored_baseline: settle,
      }))
    );
  }

  @action
  previousDelivery() {
    return this.loadDelivery(this.deliveryPage - 1);
  }

  @action
  nextDelivery() {
    return this.loadDelivery(this.deliveryPage + 1);
  }

  @action
  selected(field, value) {
    return this.form[field].includes(value);
  }

  @action
  updateText(field, event) {
    this.form = { ...this.form, [field]: event.target.value };
    this.notice = "";
  }

  @action
  updateBoolean(field, event) {
    this.form = { ...this.form, [field]: event.target.checked };
    this.notice = "";
  }

  @action
  updateSelection(field, value, event) {
    const current = this.form[field];
    this.form = {
      ...this.form,
      [field]: event.target.checked
        ? [...current.filter((item) => item !== value), value]
        : current.filter((item) => item !== value),
    };
    this.notice = "";
  }

  @action
  async open() {
    this.opened = true;
    await this.loadConfiguration();
  }

  @action
  close() {
    this.loadSequence++;
    this.previewSequence++;
    this.catalogSequences.authors++;
    this.catalogSequences.taxonomy++;
    this.opened = false;
    this.loading = false;
    this.loadingPreview = false;
  }

  applyConfiguration(configuration) {
    this.previewSequence++;
    this.preview = null;
    this.loadingPreview = false;
    this.configured = Boolean(configuration);
    this.expectedPolicyRevision = configuration?.policy.policy_revision ?? null;
    this.authorIds = [...(configuration?.policy.author_ids || [])];
    this.taxonomyIds = [...(configuration?.policy.taxonomy_ids || [])];
    const form = emptyForm();
    if (configuration) {
      const policy = configuration.policy;
      const capabilities = configuration.native_capabilities;
      Object.assign(form, {
        profile: configuration.profile,
        destinationOrigin: configuration.destination_origin,
        publicationLane:
          configuration.publication_lane === ""
            ? DEFAULT_LANE
            : configuration.publication_lane,
        nativeRevision: capabilities.native_revision,
        publicationKind: capabilities.publication_kind,
        supportedPresentations: [...capabilities.supported_presentations],
        completeContent: capabilities.complete_content_supported
          ? "true"
          : "false",
        enabled: policy.enabled,
        sourceSelection: policy.selection,
        categoryIds: [...policy.category_ids],
        includeTopicIds: policy.include_topic_ids.join("\n"),
        excludeTopicIds: policy.exclude_topic_ids.join("\n"),
        includeUnlisted: policy.include_unlisted,
        presentationMode: policy.presentation_mode,
      });
    }
    this.form = form;
    this.loaded = true;
    this.revisionConflict = false;
  }

  async loadInspectionReads() {
    if (this.configured) {
      return Promise.all([
        this.loadDelivery(),
        this.loadCatalog("authors"),
        this.loadCatalog("taxonomy"),
      ]);
    }
    this.catalogStates = { authors: {}, taxonomy: {} };
    return this.loadDelivery();
  }

  @action
  async loadConfiguration() {
    const sequence = ++this.loadSequence;
    this.loading = true;
    this.loaded = false;
    this.notice = "";
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-configuration.json`
      );
      if (sequence === this.loadSequence && !this.isDestroying) {
        this.applyConfiguration(result.cms_configuration);
        await this.loadInspectionReads();
      }
    } catch (error) {
      if (sequence === this.loadSequence && !this.isDestroying) {
        this.notice = i18n(`${PREFIX}.load_failed`);
        popupAjaxError(error);
      }
    } finally {
      if (sequence === this.loadSequence && !this.isDestroying) {
        this.loading = false;
      }
    }
  }

  topicIds(text) {
    // Core identities remain decimal strings; never convert them through Number.
    const ids = text.split(/\r?\n/).filter((value) => value !== "");
    const maximum = "9223372036854775807";
    if (
      ids.some(
        (id) =>
          !/^[1-9][0-9]{0,18}$/.test(id) ||
          (id.length === maximum.length && id > maximum)
      ) ||
      new Set(ids).size !== ids.length
    ) {
      throw new Error(i18n(`${PREFIX}.invalid_topic_ids`));
    }
    return ids;
  }

  configurationInput() {
    const form = this.form;
    const lane = this.laneChoices.find(
      (choice) => choice.value === form.publicationLane
    );
    if (!lane || !["true", "false"].includes(form.completeContent)) {
      throw new Error(i18n(`${PREFIX}.required_choices`));
    }
    if (form.enabled && !this.canPublishFrom) {
      throw new Error(i18n(`${PREFIX}.from_required`));
    }
    return {
      profile: form.profile,
      destination_origin: form.destinationOrigin,
      publication_lane: lane.wireValue,
      native_capabilities: {
        native_revision: form.nativeRevision,
        supported_presentations: [...form.supportedPresentations],
        publication_kind: form.publicationKind,
        complete_content_supported: form.completeContent === "true",
      },
      policy: {
        enabled: form.enabled,
        selection: form.sourceSelection,
        category_ids:
          form.sourceSelection === "categories" ? [...form.categoryIds] : [],
        include_topic_ids: this.topicIds(form.includeTopicIds),
        exclude_topic_ids: this.topicIds(form.excludeTopicIds),
        include_unlisted: form.includeUnlisted,
        publication_kind: form.publicationKind,
        presentation_mode: form.presentationMode,
        author_ids: [...this.authorIds],
        taxonomy_ids: [...this.taxonomyIds],
      },
    };
  }

  @action
  async save(event) {
    event.preventDefault();
    if (this.saveDisabled) {
      return;
    }
    let data;
    try {
      data = JSON.stringify({
        expected_policy_revision: this.expectedPolicyRevision,
        configuration: this.configurationInput(),
      });
      if (new TextEncoder().encode(data).byteLength > 65_536) {
        throw new Error(i18n(`${PREFIX}.request_too_large`));
      }
    } catch (error) {
      this.notice = error.message;
      return;
    }
    this.saving = true;
    this.notice = "";
    try {
      const result = await ajax(
        `/admin/content-connections/${this.args.connection.id}/cms-configuration.json`,
        {
          type: "PUT",
          contentType: "application/json",
          processData: false,
          data,
        }
      );
      if (!this.isDestroying) {
        this.applyConfiguration(result.cms_configuration);
        this.notice = i18n(`${PREFIX}.saved`);
        await this.loadInspectionReads();
      }
    } catch (error) {
      if (!this.isDestroying) {
        const code =
          error?.jqXHR?.responseJSON?.code || error?.responseJSON?.code;
        this.revisionConflict = code === "revision_conflict";
        if (this.revisionConflict) {
          this.notice = i18n(`${PREFIX}.revision_conflict`);
        } else {
          popupAjaxError(error);
        }
      }
    } finally {
      if (!this.isDestroying) {
        this.saving = false;
      }
    }
  }

  <template>
    {{#if this.profiles.length}}
      <section class="discussion-bridge-cms-configuration">
        {{#if this.opened}}
          <h4>{{i18n "discussion_bridge.admin.cms.title"}}</h4>
          <p>{{i18n "discussion_bridge.admin.cms.description"}}</p>
          <section class="discussion-bridge-cms-preview">
            <h5>{{i18n "discussion_bridge.admin.cms.preview_title"}}</h5>
            <p>{{i18n "discussion_bridge.admin.cms.preview_help"}}</p>
            <label>{{i18n "discussion_bridge.admin.cms.preview_topic"}}
              <input
                value={{this.previewTopicId}}
                {{on "input" this.updatePreviewTopic}}
              />
            </label>
            <DButton
              @action={{this.loadPreview}}
              @disabled={{this.previewDisabled}}
              @label="discussion_bridge.admin.cms.preview_load"
            />
            {{#if this.preview}}
              <h6>{{this.preview.title}}</h6>
              <p><a href={{this.preview.native_source_url}}>{{i18n
                    "discussion_bridge.admin.cms.preview_full_source"
                  }}</a></p>
              <p>{{i18n "discussion_bridge.admin.cms.preview_plan"}}:
                {{this.previewMode this.preview.presentation_mode}}
                ·
                {{this.preview.native_capabilities.native_revision}}
                ·
                {{this.preview.policy_revision}}</p>
              <p>{{i18n "discussion_bridge.admin.cms.preview_eligibility"}}:
                {{this.previewFlag this.preview.selection_eligible}}
                /
                {{this.previewFlag this.preview.publication_enabled}}
                /
                {{this.previewFlag this.preview.publication_eligible}}</p>
              <p>{{i18n "discussion_bridge.admin.cms.preview_native"}}:
                {{this.preview.native_first_post_id}}
                /
                {{this.preview.native_version}}
                /
                {{this.previewFlag this.preview.wiki}}</p>
              <p>{{i18n "discussion_bridge.admin.cms.selected_author_ids"}}:
                {{this.preview.author_ids}}</p>
              <p>{{i18n "discussion_bridge.admin.cms.selected_taxonomy_ids"}}:
                {{this.preview.taxonomy_ids}}</p>
              {{#unless this.preview.selection_availability.available}}<p
                  role="status"
                >{{i18n
                    "discussion_bridge.admin.cms.catalog_attention"
                  }}</p>{{/unless}}
              {{#if this.preview.source}}
                <p>{{this.preview.source.content_bytes}}
                  ·
                  <code>{{this.preview.source.content_sha256}}</code></p>
                <p>{{this.preview.source.source_created_at}}
                  ·
                  {{this.preview.source.source_updated_at}}</p>
                <p>{{i18n "discussion_bridge.admin.cms.preview_text"}}</p>
                <pre>{{this.preview.source_text}}</pre>
                {{#if this.preview.source_text_truncated}}<p>{{i18n
                      "discussion_bridge.admin.cms.preview_excerpt"
                    }}</p>{{/if}}
              {{else}}<p>{{i18n
                    "discussion_bridge.admin.cms.preview_unselected"
                  }}</p>{{/if}}
            {{/if}}
          </section>
          <section class="discussion-bridge-cms-delivery">
            <h5>{{i18n "discussion_bridge.admin.cms.delivery_title"}}</h5>
            <p>{{i18n "discussion_bridge.admin.cms.delivery_help"}}</p>
            <p>{{i18n "discussion_bridge.admin.cms.attention_help"}}</p>
            <DButton
              @action={{fn this.checkAttention null}}
              @disabled={{this.checkAttentionDisabled}}
              @label="discussion_bridge.admin.cms.check_selected"
            />
            <DButton
              @action={{fn this.retryAttention null false}}
              @disabled={{this.retryAttentionDisabled}}
              @label="discussion_bridge.admin.cms.retry_selected"
            />
            <DButton
              @action={{fn this.retryAttention null true}}
              @disabled={{this.settleAttentionDisabled}}
              @label="discussion_bridge.admin.cms.settle_selected"
            />
            {{#each this.attentionResults as |result|}}
              <p role="status"><code>{{result.work_id}}</code>
                ·
                {{this.inspectionStatus result.status}}
                ·
                {{result.issue}}</p>
            {{/each}}
            {{#if this.loadingDelivery}}
              <p role="status">{{i18n
                  "discussion_bridge.admin.cms.delivery_loading"
                }}</p>
            {{else if this.deliveryAvailable}}
              {{#each this.deliveries as |delivery|}}
                <article data-mapping-id={{delivery.mapping_id}}>
                  <h6>{{delivery.topic_title}}</h6>
                  <p><code>{{delivery.mapping_id}}</code>
                    ·
                    {{this.deliveryStatus delivery.publication_status}}</p>
                  {{#if delivery.attention_required}}
                    <p role="status"><strong>{{i18n
                          "discussion_bridge.admin.cms.withdrawal_attention"
                        }}</strong></p>
                  {{/if}}
                  {{#if delivery.attention_recovery.metadata_restored}}
                    <p role="status">{{i18n
                        "discussion_bridge.admin.cms.metadata_restored"
                      }}</p>
                  {{/if}}
                  {{#if delivery.attention_recovery.can_check}}
                    <label><input
                        checked={{this.attentionSelected delivery.work.work_id}}
                        disabled={{this.attentionBusy}}
                        type="checkbox"
                        {{on
                          "change"
                          (fn this.selectAttention delivery.work.work_id)
                        }}
                      />
                      {{i18n "discussion_bridge.admin.cms.select_attention"}}:
                      {{delivery.topic_title}}</label>
                    <DButton
                      @action={{fn this.checkAttention delivery}}
                      @disabled={{this.attentionBusy}}
                      @label="discussion_bridge.admin.cms.check_native"
                    />
                    {{#if delivery.attention_recovery.inspection}}
                      <p role="status">{{this.inspectionStatus
                          delivery.attention_recovery.inspection.status
                        }}
                        ·
                        {{delivery.attention_recovery.inspection.issue}}
                        ·
                        {{delivery.attention_recovery.inspection.observed_at}}</p>
                      {{#if
                        (eq
                          delivery.attention_recovery.inspection.status "ready"
                        )
                      }}
                        {{#if delivery.attention_recovery.settlement_required}}
                          <p>{{i18n
                              "discussion_bridge.admin.cms.settlement_effect"
                            }}</p>
                          <DButton
                            @action={{fn this.retryAttention delivery true}}
                            @disabled={{this.attentionBusy}}
                            @label="discussion_bridge.admin.cms.settle_retry"
                          />
                        {{else}}
                          <DButton
                            @action={{fn this.retryAttention delivery false}}
                            @disabled={{this.attentionBusy}}
                            @label="discussion_bridge.admin.cms.retry_one"
                          />
                        {{/if}}
                      {{/if}}
                    {{/if}}
                  {{/if}}
                  <dl>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_eligibility"
                      }}</dt>
                    <dd>{{#if delivery.publication_eligible}}
                        {{i18n "discussion_bridge.admin.cms.delivery_eligible"}}
                      {{else}}{{i18n
                          "discussion_bridge.admin.cms.delivery_ineligible"
                        }}{{/if}}
                      ·
                      {{delivery.scope_issue}}</dd>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_source_dates"
                      }}</dt>
                    <dd>{{delivery.source_created_at}}
                      ·
                      {{delivery.source_updated_at}}</dd>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_desired"
                      }}</dt>
                    <dd><code>{{delivery.desired_source_revision}}</code></dd>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_synchronized"
                      }}</dt>
                    <dd><code>{{delivery.synchronized_source_revision}}</code>
                      ·
                      {{delivery.synchronized_at}}</dd>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_verified"
                      }}</dt>
                    <dd><code
                      >{{delivery.publicly_verified_source_revision}}</code>
                      ·
                      {{delivery.publicly_verified_at}}</dd>
                    <dt>{{i18n
                        "discussion_bridge.admin.cms.delivery_work"
                      }}</dt>
                    <dd>{{this.workAction delivery.work.action}}
                      ·
                      {{this.deliveryStatus delivery.work.state}}
                      ·
                      {{delivery.work.attempt}}
                      /
                      {{delivery.work.attempt_ceiling}}
                      ·
                      {{delivery.work.retry_at}}
                      ·
                      {{delivery.work.last_failure_code}}</dd>
                  </dl>
                </article>
              {{else}}
                <p>{{i18n "discussion_bridge.admin.cms.delivery_empty"}}</p>
              {{/each}}
              <DButton
                @action={{this.previousDelivery}}
                @disabled={{this.deliveryPreviousDisabled}}
                @label="discussion_bridge.admin.cms.delivery_previous"
              />
              <span>{{this.deliveryPage}} / {{this.deliveryPages}}</span>
              <DButton
                @action={{this.nextDelivery}}
                @disabled={{this.deliveryNextDisabled}}
                @label="discussion_bridge.admin.cms.delivery_next"
              />
            {{else}}
              <p>{{i18n "discussion_bridge.admin.cms.delivery_failed"}}</p>
            {{/if}}
            <DButton
              @action={{this.reloadDelivery}}
              @disabled={{this.loadingDelivery}}
              @label="discussion_bridge.admin.cms.delivery_refresh"
            />
          </section>
          {{#if this.notice}}<p role="status">{{this.notice}}</p>{{/if}}
          {{#if this.loading}}
            <p role="status">{{i18n "discussion_bridge.admin.cms.loading"}}</p>
          {{else if this.loaded}}
            <form
              class="discussion-bridge-add-connection"
              {{on "submit" this.save}}
            >
              <label>{{i18n "discussion_bridge.admin.cms.profile"}}
                <select required {{on "change" (fn this.updateText "profile")}}>
                  <option selected={{eq this.form.profile ""}} value="">{{i18n
                      "discussion_bridge.admin.cms.choose"
                    }}</option>
                  {{#each this.profileChoices as |choice|}}
                    <option
                      selected={{eq this.form.profile choice.value}}
                      value={{choice.value}}
                    >{{choice.label}}</option>
                  {{/each}}
                </select>
              </label>
              <label>{{i18n "discussion_bridge.admin.cms.destination_origin"}}
                <select
                  required
                  {{on "change" (fn this.updateText "destinationOrigin")}}
                >
                  <option
                    selected={{eq this.form.destinationOrigin ""}}
                    value=""
                  >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                  {{#each this.originChoices as |choice|}}
                    <option
                      selected={{eq this.form.destinationOrigin choice.value}}
                      value={{choice.value}}
                    >{{choice.label}}</option>
                  {{/each}}
                </select>
                <small>{{i18n
                    "discussion_bridge.admin.cms.origin_help"
                  }}</small>
              </label>
              <label>{{i18n "discussion_bridge.admin.cms.publication_lane"}}
                <select
                  required
                  {{on "change" (fn this.updateText "publicationLane")}}
                >
                  <option
                    selected={{eq this.form.publicationLane ""}}
                    value=""
                  >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                  {{#each this.laneChoices as |choice|}}
                    <option
                      selected={{eq this.form.publicationLane choice.value}}
                      value={{choice.value}}
                    >{{choice.label}}</option>
                  {{/each}}
                </select>
              </label>
              <fieldset>
                <legend>{{i18n
                    "discussion_bridge.admin.cms.native_capabilities"
                  }}</legend>
                <p>{{i18n "discussion_bridge.admin.cms.capabilities_help"}}</p>
                <label>{{i18n "discussion_bridge.admin.cms.native_revision"}}
                  <input
                    required
                    value={{this.form.nativeRevision}}
                    {{on "input" (fn this.updateText "nativeRevision")}}
                  />
                </label>
                <label>{{i18n "discussion_bridge.admin.cms.publication_kind"}}
                  <select
                    required
                    {{on "change" (fn this.updateText "publicationKind")}}
                  >
                    <option
                      selected={{eq this.form.publicationKind ""}}
                      value=""
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      selected={{eq this.form.publicationKind "dynamic"}}
                      value="dynamic"
                    >{{i18n "discussion_bridge.admin.cms.dynamic"}}</option>
                    <option
                      selected={{eq this.form.publicationKind "static"}}
                      value="static"
                    >{{i18n "discussion_bridge.admin.cms.static"}}</option>
                  </select>
                </label>
                <fieldset>
                  <legend>{{i18n
                      "discussion_bridge.admin.cms.supported_presentations"
                    }}</legend>
                  {{#each this.modes as |mode|}}
                    <label class="discussion-bridge-direction-option">
                      <input
                        checked={{this.selected
                          "supportedPresentations"
                          mode.value
                        }}
                        type="checkbox"
                        {{on
                          "change"
                          (fn
                            this.updateSelection
                            "supportedPresentations"
                            mode.value
                          )
                        }}
                      />
                      <span>{{mode.label}}</span>
                    </label>
                  {{/each}}
                </fieldset>
                <label>{{i18n "discussion_bridge.admin.cms.complete_content"}}
                  <select
                    required
                    {{on "change" (fn this.updateText "completeContent")}}
                  >
                    <option
                      selected={{eq this.form.completeContent ""}}
                      value=""
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      selected={{eq this.form.completeContent "true"}}
                      value="true"
                    >{{i18n "discussion_bridge.admin.cms.supported"}}</option>
                    <option
                      selected={{eq this.form.completeContent "false"}}
                      value="false"
                    >{{i18n "discussion_bridge.admin.cms.unsupported"}}</option>
                  </select>
                </label>
              </fieldset>
              <fieldset>
                <legend>{{i18n
                    "discussion_bridge.admin.cms.publication_policy"
                  }}</legend>
                <label class="discussion-bridge-direction-option">
                  <input
                    checked={{this.form.enabled}}
                    disabled={{this.enableDisabled}}
                    type="checkbox"
                    {{on "change" (fn this.updateBoolean "enabled")}}
                  />
                  <span>{{i18n
                      "discussion_bridge.admin.cms.enable_publication"
                    }}</span>
                </label>
                {{#unless this.canPublishFrom}}<p>{{i18n
                      "discussion_bridge.admin.cms.from_required"
                    }}</p>{{/unless}}
                {{#unless @connection.enabled}}<p>{{i18n
                      "discussion_bridge.admin.cms.connection_disabled"
                    }}</p>{{/unless}}
                <label>{{i18n "discussion_bridge.admin.cms.source_selection"}}
                  <select
                    required
                    {{on "change" (fn this.updateText "sourceSelection")}}
                  >
                    <option
                      selected={{eq this.form.sourceSelection ""}}
                      value=""
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      selected={{eq this.form.sourceSelection "categories"}}
                      value="categories"
                    >{{i18n
                        "discussion_bridge.admin.cms.selected_categories"
                      }}</option>
                    <option
                      selected={{eq this.form.sourceSelection "all_public"}}
                      value="all_public"
                    >{{i18n "discussion_bridge.admin.cms.all_public"}}</option>
                  </select>
                </label>
                {{#if (eq this.form.sourceSelection "categories")}}
                  <fieldset>
                    <legend>{{i18n
                        "discussion_bridge.admin.cms.categories"
                      }}</legend>
                    <p>{{i18n
                        "discussion_bridge.admin.cms.category_eligibility"
                      }}</p>
                    {{#each this.sourceCategories as |category|}}
                      <label class="discussion-bridge-direction-option">
                        <input
                          checked={{this.selected "categoryIds" category.id}}
                          type="checkbox"
                          {{on
                            "change"
                            (fn this.updateSelection "categoryIds" category.id)
                          }}
                        />
                        <span>{{category.label}}
                          <code>{{category.id}}</code></span>
                      </label>
                    {{/each}}
                  </fieldset>
                {{/if}}
                <label>{{i18n "discussion_bridge.admin.cms.include_topics"}}
                  <textarea
                    value={{this.form.includeTopicIds}}
                    {{on "input" (fn this.updateText "includeTopicIds")}}
                  ></textarea>
                </label>
                <label>{{i18n "discussion_bridge.admin.cms.exclude_topics"}}
                  <textarea
                    value={{this.form.excludeTopicIds}}
                    {{on "input" (fn this.updateText "excludeTopicIds")}}
                  ></textarea>
                  <small>{{i18n
                      "discussion_bridge.admin.cms.topic_eligibility"
                    }}</small>
                </label>
                <label class="discussion-bridge-direction-option">
                  <input
                    checked={{this.form.includeUnlisted}}
                    type="checkbox"
                    {{on "change" (fn this.updateBoolean "includeUnlisted")}}
                  />
                  <span>{{i18n
                      "discussion_bridge.admin.cms.include_unlisted"
                    }}</span>
                </label>
                <label>{{i18n "discussion_bridge.admin.cms.presentation_mode"}}
                  <select
                    required
                    {{on "change" (fn this.updateText "presentationMode")}}
                  >
                    <option
                      selected={{eq this.form.presentationMode ""}}
                      value=""
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    {{#each this.chosenPresentationModes as |mode|}}
                      <option
                        selected={{eq this.form.presentationMode mode.value}}
                        value={{mode.value}}
                      >{{mode.label}}</option>
                    {{/each}}
                  </select>
                </label>
              </fieldset>
              <fieldset>
                <legend>{{i18n
                    "discussion_bridge.admin.cms.destination_metadata"
                  }}</legend>
                <p>{{i18n
                    "discussion_bridge.admin.cms.catalog_refresh_help"
                  }}</p>
                <p>{{i18n "discussion_bridge.admin.cms.empty_metadata"}}</p>
                {{#each this.catalogPanels as |catalog|}}
                  <h6>{{catalog.label}}</h6>
                  <DButton
                    @action={{fn this.reloadCatalog catalog.kind}}
                    @disabled={{catalog.loading}}
                    @label="discussion_bridge.admin.cms.catalog_reload"
                  />
                  {{#if catalog.loading}}<p>{{i18n
                        "discussion_bridge.admin.cms.catalog_loading"
                      }}</p>
                  {{else if catalog.available}}
                    <p>{{i18n "discussion_bridge.admin.cms.catalog_revision"}}:
                      {{catalog.catalogRevision}}
                      /
                      {{catalog.currentRevision}}</p>
                    {{#if catalog.stale}}<p role="status">{{i18n
                          "discussion_bridge.admin.cms.catalog_stale"
                        }}</p>{{/if}}
                    {{#each catalog.items as |entry|}}
                      <label><input
                          checked={{this.metadataSelected
                            catalog.field
                            entry.id
                          }}
                          disabled={{entry.disabled}}
                          type="checkbox"
                          {{on
                            "change"
                            (fn this.updateMetadata catalog.field entry.id)
                          }}
                        />
                        {{entry.label}}
                        ·
                        <code>{{entry.id}}</code>
                        {{#unless entry.available}}{{i18n
                            "discussion_bridge.admin.cms.catalog_item_unavailable"
                          }}{{/unless}}</label>
                    {{/each}}
                    <DButton
                      @action={{fn
                        this.nextCatalog
                        catalog.kind
                        catalog.nextCursor
                      }}
                      @disabled={{catalog.nextDisabled}}
                      @label="discussion_bridge.admin.cms.catalog_next"
                    />
                  {{else}}<p role="status">{{i18n
                        "discussion_bridge.admin.cms.catalog_unavailable"
                      }}</p>{{/if}}
                  {{#if catalog.missing.length}}<p role="status">{{i18n
                        "discussion_bridge.admin.cms.catalog_attention"
                      }}:
                      {{catalog.missing}}</p>{{/if}}
                  {{#if catalog.unavailable.length}}<p role="status">{{i18n
                        "discussion_bridge.admin.cms.catalog_attention"
                      }}:
                      {{catalog.unavailable}}</p>{{/if}}
                  {{#if catalog.error}}<p role="status">{{i18n
                        "discussion_bridge.admin.cms.catalog_attention"
                      }}:
                      {{catalog.error}}</p>{{/if}}
                  <ul>{{#each catalog.selected as |id|}}<li><code>{{id}}</code>
                        <DButton
                          @action={{fn this.removeMetadata catalog.field id}}
                          @label="discussion_bridge.admin.cms.catalog_remove"
                        />
                      </li>{{else}}<li>{{i18n
                          "discussion_bridge.admin.cms.no_selection"
                        }}</li>{{/each}}</ul>
                {{/each}}
              </fieldset>
              <DButton
                class="btn-primary"
                @disabled={{this.saveDisabled}}
                @label="discussion_bridge.admin.cms.save"
                @type="submit"
              />
            </form>
          {{/if}}
          <DButton
            @action={{this.loadConfiguration}}
            @disabled={{this.busy}}
            @label="discussion_bridge.admin.cms.reload"
          />
          <DButton
            @action={{this.close}}
            @disabled={{this.saving}}
            @label="discussion_bridge.admin.cancel"
          />
        {{else}}
          <DButton
            @action={{this.open}}
            @label="discussion_bridge.admin.cms.configure"
          />
        {{/if}}
      </section>
    {{/if}}
  </template>
}
