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
    adoptionEnabled: false,
    adoptableResourceIds: [],
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
  @tracked loadingRecords = false;
  @tracked recordsAvailable = false;
  @tracked ownedRecords = [];
  @tracked recordsPage = 1;
  @tracked recordsPages = 1;

  loadSequence = 0;
  recordsSequence = 0;

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

  get selectedAdoptionIds() {
    return this.form.adoptableResourceIds;
  }

  get busy() {
    return this.loading || this.saving;
  }

  get saveDisabled() {
    return this.busy || !this.loaded || this.revisionConflict;
  }

  get previousRecordsDisabled() {
    return this.loadingRecords || this.recordsPage <= 1;
  }

  get nextRecordsDisabled() {
    return this.loadingRecords || this.recordsPage >= this.recordsPages;
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
  updateAdoption(event) {
    const enabled = event.target.checked;
    this.form = {
      ...this.form,
      adoptionEnabled: enabled,
      adoptableResourceIds: enabled ? this.form.adoptableResourceIds : [],
    };
    this.notice = "";
  }

  @action
  removeAdoptionId(id) {
    this.form = {
      ...this.form,
      adoptableResourceIds: this.form.adoptableResourceIds.filter(
        (value) => value !== id
      ),
    };
    this.notice = "";
  }

  @action
  async open() {
    this.opened = true;
    await Promise.all([this.loadConfiguration(), this.loadOwnedRecords(1)]);
  }

  @action
  close() {
    this.loadSequence++;
    this.recordsSequence++;
    this.opened = false;
    this.loading = false;
    this.loadingRecords = false;
  }

  applyConfiguration(configuration) {
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
        adoptionEnabled:
          policy.existing_record_adoption === "explicit_records_only",
        adoptableResourceIds: [...policy.adoptable_resource_ids],
      });
    }
    this.form = form;
    this.loaded = true;
    this.revisionConflict = false;
  }

  @action
  async loadConfiguration() {
    const sequence = ++this.loadSequence;
    this.loading = true;
    this.loaded = false;
    this.notice = "";
    try {
      const result = await ajax(
        `/discussion-bridge/admin/content-connections/${this.args.connection.id}/cms-configuration.json`
      );
      if (
        sequence === this.loadSequence &&
        !this.isDestroying &&
        !this.isDestroyed
      ) {
        this.applyConfiguration(result.cms_configuration);
      }
    } catch (error) {
      if (
        sequence === this.loadSequence &&
        !this.isDestroying &&
        !this.isDestroyed
      ) {
        this.notice = i18n(`${PREFIX}.load_failed`);
        popupAjaxError(error);
      }
    } finally {
      if (
        sequence === this.loadSequence &&
        !this.isDestroying &&
        !this.isDestroyed
      ) {
        this.loading = false;
      }
    }
  }

  async loadOwnedRecords(page) {
    const sequence = ++this.recordsSequence;
    this.loadingRecords = true;
    try {
      const result = await ajax(
        "/discussion-bridge/admin/bridge-records.json",
        {
          data: {
            connection_id: this.args.connection.id,
            direction: "from_discourse",
            page,
          },
        }
      );
      if (
        sequence !== this.recordsSequence ||
        this.isDestroying ||
        this.isDestroyed
      ) {
        return;
      }
      this.ownedRecords = result.bridge_records.filter((record) => {
        const binding = record.active_binding;
        return (
          record.direction === "from_discourse" &&
          binding?.role === "presentation" &&
          binding.state === "active" &&
          String(binding.connection.id) === String(this.args.connection.id)
        );
      });
      this.recordsPage = result.pagination.page;
      this.recordsPages = result.pagination.pages;
      this.recordsAvailable = true;
    } catch (error) {
      if (
        sequence === this.recordsSequence &&
        !this.isDestroying &&
        !this.isDestroyed
      ) {
        this.recordsAvailable = false;
        popupAjaxError(error);
      }
    } finally {
      if (
        sequence === this.recordsSequence &&
        !this.isDestroying &&
        !this.isDestroyed
      ) {
        this.loadingRecords = false;
      }
    }
  }

  @action
  previousRecords() {
    return this.loadOwnedRecords(this.recordsPage - 1);
  }

  @action
  nextRecords() {
    return this.loadOwnedRecords(this.recordsPage + 1);
  }

  @action
  reloadRecords() {
    return this.loadOwnedRecords(this.recordsPage);
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
        existing_record_adoption: form.adoptionEnabled
          ? "explicit_records_only"
          : "disabled",
        adoptable_resource_ids: form.adoptionEnabled
          ? [...form.adoptableResourceIds]
          : [],
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
        `/discussion-bridge/admin/content-connections/${this.args.connection.id}/cms-configuration.json`,
        {
          type: "PUT",
          contentType: "application/json",
          processData: false,
          data,
        }
      );
      if (!this.isDestroying && !this.isDestroyed) {
        this.applyConfiguration(result.cms_configuration);
        this.notice = i18n(`${PREFIX}.saved`);
      }
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed) {
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
      if (!this.isDestroying && !this.isDestroyed) {
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
          <p>{{i18n
              "discussion_bridge.admin.cms.delivery_status_unavailable"
            }}</p>
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
                  <option value="" selected={{eq this.form.profile ""}}>{{i18n
                      "discussion_bridge.admin.cms.choose"
                    }}</option>
                  {{#each this.profileChoices as |choice|}}
                    <option
                      value={{choice.value}}
                      selected={{eq this.form.profile choice.value}}
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
                    value=""
                    selected={{eq this.form.destinationOrigin ""}}
                  >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                  {{#each this.originChoices as |choice|}}
                    <option
                      value={{choice.value}}
                      selected={{eq this.form.destinationOrigin choice.value}}
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
                    value=""
                    selected={{eq this.form.publicationLane ""}}
                  >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                  {{#each this.laneChoices as |choice|}}
                    <option
                      value={{choice.value}}
                      selected={{eq this.form.publicationLane choice.value}}
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
                      value=""
                      selected={{eq this.form.publicationKind ""}}
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      value="dynamic"
                      selected={{eq this.form.publicationKind "dynamic"}}
                    >{{i18n "discussion_bridge.admin.cms.dynamic"}}</option>
                    <option
                      value="static"
                      selected={{eq this.form.publicationKind "static"}}
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
                        type="checkbox"
                        checked={{this.selected
                          "supportedPresentations"
                          mode.value
                        }}
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
                      value=""
                      selected={{eq this.form.completeContent ""}}
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      value="true"
                      selected={{eq this.form.completeContent "true"}}
                    >{{i18n "discussion_bridge.admin.cms.supported"}}</option>
                    <option
                      value="false"
                      selected={{eq this.form.completeContent "false"}}
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
                    type="checkbox"
                    checked={{this.form.enabled}}
                    disabled={{this.enableDisabled}}
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
                      value=""
                      selected={{eq this.form.sourceSelection ""}}
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    <option
                      value="categories"
                      selected={{eq this.form.sourceSelection "categories"}}
                    >{{i18n
                        "discussion_bridge.admin.cms.selected_categories"
                      }}</option>
                    <option
                      value="all_public"
                      selected={{eq this.form.sourceSelection "all_public"}}
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
                          type="checkbox"
                          checked={{this.selected "categoryIds" category.id}}
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
                    type="checkbox"
                    checked={{this.form.includeUnlisted}}
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
                      value=""
                      selected={{eq this.form.presentationMode ""}}
                    >{{i18n "discussion_bridge.admin.cms.choose"}}</option>
                    {{#each this.chosenPresentationModes as |mode|}}
                      <option
                        value={{mode.value}}
                        selected={{eq this.form.presentationMode mode.value}}
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
                    "discussion_bridge.admin.cms.catalog_unavailable"
                  }}</p>
                <p>{{i18n "discussion_bridge.admin.cms.empty_metadata"}}</p>
                <p>{{i18n
                    "discussion_bridge.admin.cms.selected_author_ids"
                  }}</p>
                <ul>{{#each this.authorIds as |id|}}<li><code
                      >{{id}}</code></li>{{else}}<li>{{i18n
                        "discussion_bridge.admin.cms.no_selection"
                      }}</li>{{/each}}</ul>
                <p>{{i18n
                    "discussion_bridge.admin.cms.selected_taxonomy_ids"
                  }}</p>
                <ul>{{#each this.taxonomyIds as |id|}}<li><code
                      >{{id}}</code></li>{{else}}<li>{{i18n
                        "discussion_bridge.admin.cms.no_selection"
                      }}</li>{{/each}}</ul>
              </fieldset>
              <fieldset>
                <legend>{{i18n "discussion_bridge.admin.cms.adoption"}}</legend>
                <label class="discussion-bridge-direction-option">
                  <input
                    type="checkbox"
                    checked={{this.form.adoptionEnabled}}
                    {{on "change" this.updateAdoption}}
                  />
                  <span>{{i18n
                      "discussion_bridge.admin.cms.enable_adoption"
                    }}</span>
                </label>
                <p>{{i18n "discussion_bridge.admin.cms.adoption_help"}}</p>
                {{#if this.form.adoptionEnabled}}
                  {{#if this.loadingRecords}}<p role="status">{{i18n
                        "discussion_bridge.admin.cms.loading_records"
                      }}</p>{{/if}}
                  {{#if this.recordsAvailable}}
                    {{#each this.ownedRecords as |record|}}
                      <label class="discussion-bridge-direction-option">
                        <input
                          type="checkbox"
                          checked={{this.selected
                            "adoptableResourceIds"
                            record.resource_id
                          }}
                          {{on
                            "change"
                            (fn
                              this.updateSelection
                              "adoptableResourceIds"
                              record.resource_id
                            )
                          }}
                        />
                        <span>{{record.title}}
                          <code>{{record.resource_id}}</code><br /><code
                          >{{record.active_binding.external_id}}</code><br
                          />{{record.active_binding.canonical_url}}</span>
                      </label>
                    {{else}}<p>{{i18n
                          "discussion_bridge.admin.cms.no_owned_records"
                        }}</p>{{/each}}
                    <DButton
                      @label="discussion_bridge.admin.previous"
                      @action={{this.previousRecords}}
                      @disabled={{this.previousRecordsDisabled}}
                    />
                    <span>{{i18n
                        "discussion_bridge.admin.cms.records_page"
                        page=this.recordsPage
                        pages=this.recordsPages
                      }}</span>
                    <DButton
                      @label="discussion_bridge.admin.next"
                      @action={{this.nextRecords}}
                      @disabled={{this.nextRecordsDisabled}}
                    />
                  {{else}}
                    <p>{{i18n
                        "discussion_bridge.admin.cms.records_unavailable"
                      }}</p>
                    <DButton
                      @label="discussion_bridge.admin.cms.reload_records"
                      @action={{this.reloadRecords}}
                      @disabled={{this.loadingRecords}}
                    />
                  {{/if}}
                  <p>{{i18n
                      "discussion_bridge.admin.cms.selected_resources"
                    }}</p>
                  <ul>
                    {{#each this.selectedAdoptionIds as |id|}}
                      <li><code>{{id}}</code>
                        <DButton
                          @label="discussion_bridge.admin.cms.remove_resource"
                          @action={{this.removeAdoptionId}}
                          @actionParam={{id}}
                        /></li>
                    {{else}}<li>{{i18n
                          "discussion_bridge.admin.cms.no_selection"
                        }}</li>{{/each}}
                  </ul>
                  <small>{{i18n
                      "discussion_bridge.admin.cms.stored_resources_help"
                    }}</small>
                {{/if}}
              </fieldset>
              <DButton
                @type="submit"
                @label="discussion_bridge.admin.cms.save"
                @disabled={{this.saveDisabled}}
                class="btn-primary"
              />
            </form>
          {{/if}}
          <DButton
            @label="discussion_bridge.admin.cms.reload"
            @action={{this.loadConfiguration}}
            @disabled={{this.busy}}
          />
          <DButton
            @label="discussion_bridge.admin.cancel"
            @action={{this.close}}
            @disabled={{this.saving}}
          />
        {{else}}
          <DButton
            @label="discussion_bridge.admin.cms.configure"
            @action={{this.open}}
          />
        {{/if}}
      </section>
    {{/if}}
  </template>
}
