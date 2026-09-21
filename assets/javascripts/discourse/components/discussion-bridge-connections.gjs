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

export default class DiscussionBridgeConnections extends Component {
  @service router;
  @service dialog;

  @tracked name = "";
  @tracked platform = "";
  @tracked authorUsername = "";
  @tracked authorshipMode = "fixed";
  @tracked unmappedAuthorPolicy = "fallback";
  @tracked editingTab = "general";
  @tracked sourceMappings = {};
  @tracked origins = "";
  @tracked lanes = "";
  @tracked defaultCategoryId = "";
  @tracked toDiscourse = true;
  @tracked fromDiscourse = true;
  @tracked generateTopicToc = false;
  @tracked includeSourceInPublishedUrl = false;
  @tracked publicationSourcePath = "";
  @tracked forumPublicationEnabled = false;
  @tracked publicationIncludeUnlisted = false;
  @tracked publicationCategoryMode = "all_except_selected";
  @tracked publicationCategoryIds = [];
  @tracked publicationExcludedCategoryIds = [];
  @tracked publicationTagMode = "all";
  @tracked publicationTagIds = [];
  @tracked publicationExcludedTagIds = [];
  @tracked publicationTagOptions = [];
  @tracked publicationTagQuery = "";
  @tracked destinationCategoryMappings = {};
  @tracked destinationTagMappings = {};
  @tracked unmappedCategoryPolicy = "hold";
  @tracked defaultDestinationContainerId = "";
  @tracked unmappedTagPolicy = "omit";
  @tracked presentationMode = "native";
  @tracked destinationAuthorshipPolicy = "service_author";
  @tracked destinationAuthorId = "";
  @tracked destinationSlugPolicy = "platform_default";
  @tracked publicationPreview = null;
  @tracked issuedSecret = null;
  @tracked issuedConnectionId = null;
  @tracked copiedCredential = null;
  @tracked editingConnectionId = null;

  constructor() {
    super(...arguments);
    this.publicationTagOptions = this.args.model.publication_tags ?? [];
  }

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
  showGeneralTab() {
    this.editingTab = "general";
  }

  @action
  showAuthorsTab() {
    this.editingTab = "authors";
  }

  @action
  showMappingTab() {
    this.editingTab = "mapping";
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
  updateIncludeSourceInPublishedUrl(event) {
    this.includeSourceInPublishedUrl = event.target.checked;
  }

  @action
  updatePublicationSourcePath(event) {
    this.publicationSourcePath = event.target.value.toLowerCase();
  }

  @action
  updateForumPublicationEnabled(event) {
    this.forumPublicationEnabled = event.target.checked;
  }

  @action
  updatePublicationIncludeUnlisted(event) {
    this.publicationIncludeUnlisted = event.target.checked;
  }

  @action
  updatePublicationCategoryMode(event) {
    this.publicationCategoryMode = event.target.value;
    this.publicationCategoryIds = [];
    this.publicationExcludedCategoryIds = [];
  }

  @action
  updatePublicationTagMode(event) {
    this.publicationTagMode = event.target.value;
    this.publicationTagIds = [];
    this.publicationExcludedTagIds = [];
  }

  @action
  togglePublicationCategory(categoryId, event) {
    const key =
      this.publicationCategoryMode === "only_selected"
        ? "publicationCategoryIds"
        : "publicationExcludedCategoryIds";
    this[key] = event.target.checked
      ? [...this[key], categoryId]
      : this[key].filter((id) => id !== categoryId);
  }

  @action
  togglePublicationTag(tagId, event) {
    const key =
      this.publicationTagMode === "only_selected"
        ? "publicationTagIds"
        : "publicationExcludedTagIds";
    this[key] = event.target.checked
      ? [...this[key], tagId]
      : this[key].filter((id) => id !== tagId);
  }

  @action
  async searchPublicationTags(event) {
    this.publicationTagQuery = event.target.value;
    try {
      const result = await ajax(
        "/discussion-bridge/admin/publication-tags.json",
        {
          data: { q: this.publicationTagQuery, page: 1 },
        },
      );
      const byId = new Map(
        this.publicationTagOptions.map((tag) => [tag.id, tag]),
      );
      for (const tag of result.tags) {
        byId.set(tag.id, tag);
      }
      this.publicationTagOptions = [...byId.values()].sort((a, b) =>
        a.name.localeCompare(b.name),
      );
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  updateDestinationCategory(categoryId, event) {
    this.destinationCategoryMappings = {
      ...this.destinationCategoryMappings,
      [categoryId]: event.target.value,
    };
  }

  @action
  updateDestinationTag(tagId, event) {
    this.destinationTagMappings = {
      ...this.destinationTagMappings,
      [tagId]: event.target.value,
    };
  }

  @action
  updateUnmappedCategoryPolicy(event) {
    this.unmappedCategoryPolicy = event.target.value;
  }

  @action
  updateDefaultDestinationContainer(event) {
    this.defaultDestinationContainerId = event.target.value;
  }

  @action
  updateUnmappedTagPolicy(event) {
    this.unmappedTagPolicy = event.target.value;
  }

  @action
  updatePresentationMode(event) {
    this.presentationMode = event.target.value;
  }

  @action
  updateDestinationAuthorshipPolicy(event) {
    this.destinationAuthorshipPolicy = event.target.value;
    if (this.destinationAuthorshipPolicy !== "fixed") {
      this.destinationAuthorId = "";
    }
  }

  @action
  updateDestinationAuthor(event) {
    this.destinationAuthorId = event.target.value;
  }

  @action
  updateDestinationSlugPolicy(event) {
    this.destinationSlugPolicy = event.target.value;
  }

  @action
  async loadPublicationPreview() {
    try {
      this.publicationPreview = await ajax(
        `/discussion-bridge/admin/content-connections/${this.editingConnectionId}/publication-preview.json`,
      );
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async copyCredential(kind, value) {
    try {
      await navigator.clipboard.writeText(value);
      this.copiedCredential = kind;
      window.setTimeout(() => {
        if (this.copiedCredential === kind) {
          this.copiedCredential = null;
        }
      }, 2000);
    } catch {
      this.dialog.alert(i18n("discussion_bridge.admin.credential_copy_failed"));
    }
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
    try {
      const editing = this.editingConnectionId;
      const attributes = {
        name: this.name,
        platform: this.platform,
        author_username: this.authorUsername,
        authorship_mode: this.authorshipMode,
        unmapped_author_policy: this.unmappedAuthorPolicy,
        generate_topic_toc: this.generateTopicToc,
        include_source_in_published_url: this.includeSourceInPublishedUrl,
        publication_source_path: this.publicationSourcePath,
        forum_publication_enabled: this.forumPublicationEnabled,
        publication_include_unlisted: this.publicationIncludeUnlisted,
        publication_category_mode: this.publicationCategoryMode,
        publication_category_ids: this.publicationCategoryIds,
        publication_excluded_category_ids: this.publicationExcludedCategoryIds,
        publication_tag_mode: this.publicationTagMode,
        publication_tag_ids: this.publicationTagIds,
        publication_excluded_tag_ids: this.publicationExcludedTagIds,
        allowed_origins: this.lines(this.origins),
        allowed_directions: directions,
        allowed_lanes: this.lines(this.lanes),
        default_category_id: this.defaultCategoryId,
      };
      if (editing && this.editingConnection?.platform_catalog_revision) {
        attributes.destination_mapping = this.destinationMappingPayload;
      }
      const url = editing
        ? `/discussion-bridge/admin/content-connections/${editing}.json`
        : "/discussion-bridge/admin/content-connections.json";
      const result = await ajax(url, {
        type: editing ? "PUT" : "POST",
        data: {
          content_connection: attributes,
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
    this.authorUsername = connection.author_override
      ? connection.author_username
      : "";
    this.authorshipMode = connection.authorship_mode;
    this.unmappedAuthorPolicy = connection.unmapped_author_policy;
    this.editingTab = "general";
    this.sourceMappings = Object.fromEntries(
      connection.source_authors.map((author) => [
        author.id,
        author.discourse_username ?? "",
      ]),
    );
    this.origins = connection.allowed_origins.join("\n");
    this.lanes = connection.allowed_lanes.join("\n");
    this.defaultCategoryId = connection.default_category_id?.toString() ?? "";
    this.toDiscourse = connection.allowed_directions.includes("to_discourse");
    this.fromDiscourse =
      connection.allowed_directions.includes("from_discourse");
    this.generateTopicToc = connection.generate_topic_toc;
    this.includeSourceInPublishedUrl =
      connection.include_source_in_published_url;
    this.publicationSourcePath = connection.publication_source_path ?? "";
    this.forumPublicationEnabled = connection.forum_publication_enabled;
    this.publicationIncludeUnlisted = connection.publication_include_unlisted;
    this.publicationCategoryMode = connection.publication_category_mode;
    this.publicationCategoryIds = connection.publication_category_ids ?? [];
    this.publicationExcludedCategoryIds =
      connection.publication_excluded_category_ids ?? [];
    this.publicationTagMode = connection.publication_tag_mode;
    this.publicationTagIds = connection.publication_tag_ids ?? [];
    this.publicationExcludedTagIds =
      connection.publication_excluded_tag_ids ?? [];
    const mapping = connection.destination_mapping ?? {};
    this.destinationCategoryMappings = Object.fromEntries(
      (mapping.category_mappings ?? []).map((item) => [
        item.source_category_id,
        item.destination_container_id,
      ]),
    );
    this.destinationTagMappings = Object.fromEntries(
      (mapping.tag_mappings ?? []).map((item) => [
        item.source_tag_id,
        `${item.destination_taxonomy_id}|${item.destination_term_id}`,
      ]),
    );
    this.unmappedCategoryPolicy = mapping.unmapped_category_policy ?? "hold";
    this.defaultDestinationContainerId =
      mapping.default_destination_container_id ?? "";
    this.unmappedTagPolicy = mapping.unmapped_tag_policy ?? "omit";
    this.presentationMode =
      mapping.presentation_mode ??
      connection.platform_catalog?.presentation_modes?.[0] ??
      "native";
    this.destinationAuthorshipPolicy =
      mapping.authorship_policy ?? "service_author";
    this.destinationAuthorId = mapping.destination_author_id ?? "";
    this.destinationSlugPolicy = mapping.slug_policy ?? "platform_default";
    this.publicationPreview = null;
    this.scrollTo("discussion-bridge-connection-editor");
  }

  @action
  beginAddConnection() {
    this.resetForm();
    this.scrollTo("discussion-bridge-connection-editor");
  }

  @action
  cancelEdit() {
    this.resetForm();
  }

  @action
  async toggleConnection(connection) {
    try {
      await ajax(
        `/discussion-bridge/admin/content-connections/${connection.id}.json`,
        {
          type: "PUT",
          data: { content_connection: { enabled: !connection.enabled } },
        },
      );
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
    if (!confirmed) {
      return;
    }
    try {
      const result = await ajax(
        `/discussion-bridge/admin/content-connections/${connection.id}/rotate-secret.json`,
        { type: "POST" },
      );
      this.issuedSecret = result.secret;
      this.issuedConnectionId = connection.public_id;
      this.scrollTo("discussion-bridge-issued-credential");
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async requestCatalogRefresh(connection) {
    try {
      await ajax(
        `/discussion-bridge/admin/content-connections/${connection.id}/request-catalog-refresh.json`,
        { type: "POST" },
      );
      this.router.refresh();
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async saveAuthorMapping(sourceAuthor) {
    try {
      await ajax(
        `/discussion-bridge/admin/content-connections/${this.editingConnectionId}/authors/${sourceAuthor.id}.json`,
        {
          type: "PUT",
          data: {
            source_author: {
              discourse_username: this.sourceMappings[sourceAuthor.id] ?? "",
            },
          },
        },
      );
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
    this.editingConnectionId = null;
    this.name = "";
    this.platform = "";
    this.authorUsername = "";
    this.authorshipMode = "fixed";
    this.unmappedAuthorPolicy = "fallback";
    this.editingTab = "general";
    this.sourceMappings = {};
    this.origins = "";
    this.lanes = "";
    this.defaultCategoryId = "";
    this.toDiscourse = true;
    this.fromDiscourse = true;
    this.generateTopicToc = false;
    this.includeSourceInPublishedUrl = false;
    this.publicationSourcePath = "";
    this.forumPublicationEnabled = false;
    this.publicationIncludeUnlisted = false;
    this.publicationCategoryMode = "all_except_selected";
    this.publicationCategoryIds = [];
    this.publicationExcludedCategoryIds = [];
    this.publicationTagMode = "all";
    this.publicationTagIds = [];
    this.publicationExcludedTagIds = [];
    this.publicationTagQuery = "";
    this.destinationCategoryMappings = {};
    this.destinationTagMappings = {};
    this.unmappedCategoryPolicy = "hold";
    this.defaultDestinationContainerId = "";
    this.unmappedTagPolicy = "omit";
    this.presentationMode = "native";
    this.destinationAuthorshipPolicy = "service_author";
    this.destinationAuthorId = "";
    this.destinationSlugPolicy = "platform_default";
    this.publicationPreview = null;
  }

  get publicationCategories() {
    return this.args.model.publication_categories.map((category) => ({
      ...category,
      selected:
        this.publicationCategoryMode === "only_selected"
          ? this.publicationCategoryIds.includes(category.id)
          : this.publicationExcludedCategoryIds.includes(category.id),
    }));
  }

  get publicationTags() {
    const query = this.publicationTagQuery.trim().toLowerCase();
    return this.publicationTagOptions
      .filter((tag) => !query || tag.name.toLowerCase().includes(query))
      .slice(0, 200)
      .map((tag) => ({
        ...tag,
        selected:
          this.publicationTagMode === "only_selected"
            ? this.publicationTagIds.includes(tag.id)
            : this.publicationExcludedTagIds.includes(tag.id),
      }));
  }

  get editingConnection() {
    return this.args.model.content_connections.find(
      (connection) => connection.id === this.editingConnectionId,
    );
  }

  get platformContainers() {
    return this.editingConnection?.platform_catalog?.containers ?? [];
  }

  get platformTaxonomyTerms() {
    return (this.editingConnection?.platform_catalog?.taxonomies ?? []).flatMap(
      (taxonomy) =>
        taxonomy.terms.map((term) => ({
          value: `${taxonomy.id}|${term.id}`,
          label: `${taxonomy.label} / ${term.label}`,
        })),
    );
  }

  get platformPresentationModes() {
    return this.editingConnection?.platform_catalog?.presentation_modes ?? [];
  }

  get platformAuthors() {
    return this.editingConnection?.platform_catalog?.authors ?? [];
  }

  get platformInventory() {
    return this.editingConnection?.platform_catalog?.inventory;
  }

  get platformInventoryIncomplete() {
    return (
      this.platformInventory &&
      (!this.platformInventory.authors_complete ||
        !this.platformInventory.terms_complete)
    );
  }

  get mappingSourceCategories() {
    let categories;
    if (this.publicationCategoryMode === "only_selected") {
      categories = this.publicationCategories.filter(
        (category) => category.selected,
      );
    } else {
      categories = this.publicationCategories.filter(
        (category) => !category.selected,
      );
    }
    return categories.map((category) => ({
      ...category,
      destinationId: this.destinationCategoryMappings[category.id] ?? "",
    }));
  }

  get mappingSourceTags() {
    if (this.publicationTagMode === "only_selected") {
      return this.publicationTags
        .filter((tag) => this.publicationTagIds.includes(tag.id))
        .map((tag) => ({
          ...tag,
          destinationValue: this.destinationTagMappings[tag.id] ?? "",
        }));
    }
    if (this.publicationTagMode === "all_except_selected") {
      return this.publicationTags
        .filter((tag) => !this.publicationExcludedTagIds.includes(tag.id))
        .map((tag) => ({
          ...tag,
          destinationValue: this.destinationTagMappings[tag.id] ?? "",
        }));
    }
    return this.publicationTags.map((tag) => ({
      ...tag,
      destinationValue: this.destinationTagMappings[tag.id] ?? "",
    }));
  }

  get destinationMappingPayload() {
    return {
      category_mappings: Object.entries(this.destinationCategoryMappings)
        .filter(([, destinationId]) => destinationId)
        .map(([sourceId, destinationId]) => ({
          source_category_id: Number(sourceId),
          destination_container_id: destinationId,
        })),
      tag_mappings: Object.entries(this.destinationTagMappings)
        .filter(([, value]) => value)
        .map(([sourceId, value]) => {
          const [taxonomyId, termId] = value.split("|", 2);
          return {
            source_tag_id: Number(sourceId),
            destination_taxonomy_id: taxonomyId,
            destination_term_id: termId,
          };
        }),
      unmapped_category_policy: this.unmappedCategoryPolicy,
      default_destination_container_id:
        this.unmappedCategoryPolicy === "default"
          ? this.defaultDestinationContainerId
          : null,
      unmapped_tag_policy: this.unmappedTagPolicy,
      presentation_mode: this.presentationMode,
      authorship_policy: this.destinationAuthorshipPolicy,
      destination_author_id:
        this.destinationAuthorshipPolicy === "fixed"
          ? this.destinationAuthorId
          : null,
      slug_policy: this.destinationSlugPolicy,
    };
  }

  get publicationUrlPreview() {
    const origin = this.lines(this.origins)[0];
    if (!origin) {
      return "";
    }
    try {
      const path =
        this.includeSourceInPublishedUrl && this.publicationSourcePath
          ? `${this.publicationSourcePath.replace(/^\/+|\/+$/gu, "")}/`
          : "";
      return new URL(`/${path}example-page/`, origin).href;
    } catch {
      return "";
    }
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  adapterVerified(connection) {
    return Boolean(
      connection.adapter_id &&
      connection.adapter_version &&
      connection.last_seen_at,
    );
  }

  displayTimestamp(value) {
    return value ? new Date(value).toLocaleString() : "—";
  }

  connectionHealthLabel(connection) {
    if (connection.health === "healthy") {
      return i18n("discussion_bridge.admin.connection_operational");
    }

    return this.displayToken(connection.health);
  }

  scrollTo(id) {
    window.requestAnimationFrame(() => {
      const target = document.getElementById(id);
      target?.scrollIntoView({ behavior: "smooth", block: "start" });
      target?.querySelector("input, select, button")?.focus({
        preventScroll: true,
      });
    });
  }

  <template>
    <section class="discussion-bridge-connections">
      <div class="discussion-bridge-connections__header">
        <DPageSubheader
          @titleLabel={{i18n "discussion_bridge.admin.connections_title"}}
          @descriptionLabel={{i18n
            "discussion_bridge.admin.connections_description"
          }}
        />
        <DButton
          @label="discussion_bridge.admin.add_connection"
          @action={{this.beginAddConnection}}
          class="btn-primary"
        />
      </div>

      {{#if this.issuedSecret}}
        <section
          id="discussion-bridge-issued-credential"
          class="discussion-bridge-secret"
          role="status"
        >
          <strong>{{i18n "discussion_bridge.admin.secret_shown_once"}}</strong>
          <div class="discussion-bridge-secret__row">
            <span>{{i18n "discussion_bridge.admin.connection_id"}}</span>
            <code>{{this.issuedConnectionId}}</code>
            <button
              type="button"
              class="btn btn-default"
              {{on
                "click"
                (fn this.copyCredential "id" this.issuedConnectionId)
              }}
            >
              {{if
                (eq this.copiedCredential "id")
                (i18n "discussion_bridge.admin.copied")
                (i18n "discussion_bridge.admin.copy_connection_id")
              }}
            </button>
          </div>
          <div class="discussion-bridge-secret__row">
            <span>{{i18n "discussion_bridge.admin.connection_secret"}}</span>
            <code>{{this.issuedSecret}}</code>
            <button
              type="button"
              class="btn btn-default"
              {{on "click" (fn this.copyCredential "secret" this.issuedSecret)}}
            >
              {{if
                (eq this.copiedCredential "secret")
                (i18n "discussion_bridge.admin.copied")
                (i18n "discussion_bridge.admin.copy_connection_secret")
              }}
            </button>
          </div>
        </section>
      {{/if}}

      <div class="discussion-bridge-connection-grid">
        {{#each @model.content_connections as |connection|}}
          <article
            class="discussion-bridge-connection-card"
            data-health={{connection.health}}
          >
            <header>
              <div>
                <span class="discussion-bridge-platform">{{this.displayToken
                    connection.platform
                  }}</span>
                <h3>{{connection.name}}</h3>
              </div>
              <span
                class="discussion-bridge-status"
                data-state={{connection.health}}
              >{{this.connectionHealthLabel connection}}</span>
            </header>
            <dl>
              <dt>{{i18n "discussion_bridge.admin.bridge_records"}}</dt><dd
              >{{connection.bridge_record_count}}</dd>
              <dt>{{i18n "discussion_bridge.admin.connection_id"}}</dt><dd><code
                >{{connection.public_id}}</code></dd>
              <dt>{{i18n "discussion_bridge.admin.directions"}}</dt><dd
                class="discussion-bridge-connection-card__directions"
              >{{#each connection.allowed_directions as |direction|}}<span
                    class="discussion-bridge-direction"
                    data-direction={{direction}}
                  >{{this.displayToken direction}}</span>{{/each}}</dd>
              <dt>{{i18n "discussion_bridge.admin.topic_author"}}</dt><dd><code
                >{{connection.author_username}}</code>{{#unless
                  connection.author_override
                }}
                  <small>{{i18n
                      "discussion_bridge.admin.forum_default"
                    }}</small>{{/unless}}</dd>
              <dt>{{i18n "discussion_bridge.admin.authorship"}}</dt><dd
              >{{this.displayToken connection.authorship_mode}}
                ·
                {{connection.source_author_count}}
                {{i18n "discussion_bridge.admin.source_authors"}}{{#if
                  connection.unmapped_source_author_count
                }}
                  ·
                  {{connection.unmapped_source_author_count}}
                  {{i18n "discussion_bridge.admin.unresolved"}}{{/if}}</dd>
              <dt>{{i18n "discussion_bridge.admin.forum_toc"}}</dt><dd>{{if
                  connection.generate_topic_toc
                  (i18n "discussion_bridge.admin.enabled")
                  (i18n "discussion_bridge.admin.disabled")
                }}</dd>
              <dt>{{i18n
                  "discussion_bridge.admin.publication_url_path"
                }}</dt><dd>{{#if
                  connection.include_source_in_published_url
                }}<code
                  >/{{connection.publication_source_path}}/</code>{{else}}{{i18n
                    "discussion_bridge.admin.platform_native_root"
                  }}{{/if}}</dd>
              <dt>{{i18n "discussion_bridge.admin.category_route"}}</dt><dd
              >{{connection.category_route.category_name}}
                <small>({{if
                    (eq connection.category_route.source "connection")
                    (i18n "discussion_bridge.admin.connection_route")
                    (i18n "discussion_bridge.admin.forum_fallback")
                  }})</small></dd>
              <dt>{{i18n "discussion_bridge.admin.origins"}}</dt>
              <dd>
                {{#each connection.origin_readiness as |origin|}}
                  <span class="discussion-bridge-origin-readiness">
                    <code>{{origin.origin}}</code>
                    <span
                      class="discussion-bridge-status"
                      data-state={{if origin.embeddable "healthy" "setup"}}
                    >
                      {{if
                        origin.embeddable
                        (i18n "discussion_bridge.admin.embed_host_ready")
                         (i18n "discussion_bridge.admin.embedded_modes_unavailable")
                       }}
                     </span>
                    {{#unless origin.embeddable}}
                      <small>{{i18n
                          "discussion_bridge.admin.embeddable_host_explanation"
                        }}</small>
                    {{/unless}}
                  </span>
                {{/each}}
              </dd>
              <dt>{{i18n "discussion_bridge.admin.adapter_presence"}}</dt><dd
              ><span
                  class="discussion-bridge-status"
                  data-state={{if
                    (this.adapterVerified connection)
                    "healthy"
                    "setup"
                  }}
                >{{if
                    (this.adapterVerified connection)
                    (i18n "discussion_bridge.admin.adapter_verified")
                    (i18n "discussion_bridge.admin.adapter_unverified")
                  }}</span></dd>
              <dt>{{i18n "discussion_bridge.admin.adapter_identity"}}</dt><dd
              ><code>{{this.displayToken connection.adapter_id}}</code></dd>
              <dt>{{i18n "discussion_bridge.admin.adapter_version"}}</dt><dd
              ><code>{{this.displayToken
                    connection.adapter_version
                  }}</code></dd>
              <dt>{{i18n "discussion_bridge.admin.last_seen"}}</dt><dd
              >{{this.displayTimestamp connection.last_seen_at}}</dd>
              <dt>{{i18n "discussion_bridge.admin.platform_catalog"}}</dt><dd>
                {{#if connection.platform_catalog_revision}}
                  <span
                    class="discussion-bridge-status"
                    data-state={{if
                      (eq connection.destination_mapping_state "current")
                      "healthy"
                      "attention"
                    }}
                  >
                    {{if
                      (eq connection.destination_mapping_state "current")
                      (i18n "discussion_bridge.admin.mapping_ready")
                      (i18n "discussion_bridge.admin.mapping_required")
                    }}
                  </span>
                  <small>{{this.displayTimestamp
                      connection.platform_catalog_observed_at
                    }}</small>
                {{else}}
                  <span
                    class="discussion-bridge-status"
                    data-state="setup"
                  >{{i18n "discussion_bridge.admin.catalog_pending"}}</span>
                {{/if}}
              </dd>
            </dl>
            <div
              class="discussion-bridge-actions"
              aria-label={{i18n "discussion_bridge.admin.connection_actions"}}
            >
              <DButton
                @label="discussion_bridge.admin.manage"
                @action={{this.editConnection}}
                @actionParam={{connection}}
                class="btn-primary"
              />
              <DButton
                @label={{if
                  connection.enabled
                  "discussion_bridge.admin.disable"
                  "discussion_bridge.admin.enable"
                }}
                @action={{this.toggleConnection}}
                @actionParam={{connection}}
              />
              <DButton
                @label="discussion_bridge.admin.rotate_secret"
                @action={{this.rotateSecret}}
                @actionParam={{connection}}
                class="discussion-bridge-actions__credential"
              />
              <DButton
                @label="discussion_bridge.admin.refresh_platform_setup"
                @action={{this.requestCatalogRefresh}}
                @actionParam={{connection}}
              />
            </div>
          </article>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.no_connections"}}</p>
        {{/each}}
      </div>

      <form
        id="discussion-bridge-connection-editor"
        class="discussion-bridge-add-connection"
        {{on "submit" this.saveConnection}}
      >
        <h3>{{if
            this.editingConnectionId
            (i18n "discussion_bridge.admin.manage_connection")
            (i18n "discussion_bridge.admin.add_connection")
          }}</h3>
        {{#if this.editingConnectionId}}
          <nav
            class="discussion-bridge-connection-tabs"
            aria-label={{i18n
              "discussion_bridge.admin.connection_settings_tabs"
            }}
          >
            <button
              type="button"
              class={{if (eq this.editingTab "general") "active"}}
              {{on "click" this.showGeneralTab}}
            >{{i18n "discussion_bridge.admin.general_tab"}}</button>
            <button
              type="button"
              class={{if (eq this.editingTab "authors") "active"}}
              {{on "click" this.showAuthorsTab}}
            >{{i18n "discussion_bridge.admin.authors_tab"}}</button>
            <button
              type="button"
              class={{if (eq this.editingTab "mapping") "active"}}
              {{on "click" this.showMappingTab}}
            >{{i18n "discussion_bridge.admin.mapping_tab"}}</button>
          </nav>
        {{/if}}

        {{#if (eq this.editingTab "general")}}
          <label>{{i18n "discussion_bridge.admin.connection_name"}}<input
              required
              value={{this.name}}
              {{on "input" this.updateName}}
            /></label>
          <label>{{i18n "discussion_bridge.admin.platform"}}
            <select required {{on "change" this.updatePlatform}}>
              <option value="" selected={{eq this.platform ""}}>{{i18n
                  "discussion_bridge.admin.select_platform"
                }}</option>
              {{#each @model.platforms as |platform|}}<option
                  value={{platform}}
                  selected={{eq platform this.platform}}
                >{{this.displayToken platform}}</option>{{/each}}
            </select>
          </label>
          <label>{{i18n "discussion_bridge.admin.topic_author"}}<input
              value={{this.authorUsername}}
              {{on "input" this.updateAuthorUsername}}
              placeholder={{i18n
                "discussion_bridge.admin.topic_author_default"
              }}
            /></label>
          <label>{{i18n "discussion_bridge.admin.allowed_origins"}}<textarea
              required
              value={{this.origins}}
              {{on "input" this.updateOrigins}}
            ></textarea></label>
          <label>{{i18n "discussion_bridge.admin.companion_topic_category"}}
            <select {{on "change" this.updateDefaultCategory}}>
              <option value="" selected={{eq this.defaultCategoryId ""}}>
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
                  value={{category.id}}
                  selected={{eq this.defaultCategoryId category.id_string}}
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
          <label class="discussion-bridge-checkbox-setting">
            <input
              type="checkbox"
              aria-label={{i18n
                "discussion_bridge.admin.include_source_in_published_url"
              }}
              checked={{this.includeSourceInPublishedUrl}}
              {{on "change" this.updateIncludeSourceInPublishedUrl}}
            />
            <span><strong>{{i18n
                  "discussion_bridge.admin.include_source_in_published_url"
                }}</strong><small>{{i18n
                  "discussion_bridge.admin.include_source_in_published_url_description"
                }}</small></span>
          </label>
          {{#if this.includeSourceInPublishedUrl}}
            <label>{{i18n "discussion_bridge.admin.publication_source_path"}}
              <input
                required
                pattern="[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*)*"
                value={{this.publicationSourcePath}}
                {{on "input" this.updatePublicationSourcePath}}
                placeholder="from-the-bridge"
              />
              <small>{{i18n
                  "discussion_bridge.admin.publication_source_path_description"
                }}</small>
            </label>
          {{/if}}
          {{#if this.publicationUrlPreview}}
            <p class="discussion-bridge-publication-url-preview"><strong>{{i18n
                  "discussion_bridge.admin.publication_url_preview"
                }}</strong>
              <code>{{this.publicationUrlPreview}}</code></p>
          {{/if}}
          <fieldset class="discussion-bridge-direction-options">
            <legend>{{i18n
                "discussion_bridge.admin.allowed_directions"
              }}</legend>
            <label class="discussion-bridge-direction-option"><input
                type="checkbox"
                checked={{this.toDiscourse}}
                {{on "change" this.updateToDiscourse}}
              /><span>{{i18n
                  "discussion_bridge.admin.to_discourse"
                }}</span></label>
            <label class="discussion-bridge-direction-option"><input
                type="checkbox"
                checked={{this.fromDiscourse}}
                {{on "change" this.updateFromDiscourse}}
              /><span>{{i18n
                  "discussion_bridge.admin.from_discourse"
                }}</span></label>
          </fieldset>
          {{#if this.fromDiscourse}}
            <fieldset class="discussion-bridge-direction-options">
              <legend>{{i18n
                  "discussion_bridge.admin.forum_publication_scope"
                }}</legend>
              <label class="discussion-bridge-checkbox-setting"><input
                  type="checkbox"
                  checked={{this.forumPublicationEnabled}}
                  {{on "change" this.updateForumPublicationEnabled}}
                /><span><strong>{{i18n
                      "discussion_bridge.admin.forum_publication_enabled"
                    }}</strong><small>{{i18n
                      "discussion_bridge.admin.forum_publication_enabled_description"
                    }}</small></span></label>
              {{#if this.forumPublicationEnabled}}
                <label>{{i18n
                    "discussion_bridge.admin.publication_category_mode"
                  }}
                  <select {{on "change" this.updatePublicationCategoryMode}}>
                    <option
                      value="only_selected"
                      selected={{eq
                        this.publicationCategoryMode
                        "only_selected"
                      }}
                    >{{i18n
                        "discussion_bridge.admin.only_selected_categories"
                      }}</option>
                    <option
                      value="all_except_selected"
                      selected={{eq
                        this.publicationCategoryMode
                        "all_except_selected"
                      }}
                    >{{i18n
                        "discussion_bridge.admin.all_except_selected_categories"
                      }}</option>
                  </select>
                </label>
                <p>{{i18n
                    "discussion_bridge.admin.publication_categories_description"
                  }}</p>
                {{#each this.publicationCategories as |category|}}
                  <div class="discussion-bridge-direction-option">
                    <label><input
                        type="checkbox"
                        checked={{category.selected}}
                        {{on
                          "change"
                          (fn this.togglePublicationCategory category.id)
                        }}
                      />{{category.path}}</label>
                  </div>
                {{/each}}
                <label>{{i18n "discussion_bridge.admin.publication_tag_mode"}}
                  <select {{on "change" this.updatePublicationTagMode}}>
                    <option
                      value="all"
                      selected={{eq this.publicationTagMode "all"}}
                    >{{i18n "discussion_bridge.admin.all_tags"}}</option>
                    <option
                      value="only_selected"
                      selected={{eq this.publicationTagMode "only_selected"}}
                    >{{i18n
                        "discussion_bridge.admin.only_selected_tags"
                      }}</option>
                    <option
                      value="all_except_selected"
                      selected={{eq
                        this.publicationTagMode
                        "all_except_selected"
                      }}
                    >{{i18n
                        "discussion_bridge.admin.all_except_selected_tags"
                      }}</option>
                  </select>
                </label>
                {{#unless (eq this.publicationTagMode "all")}}
                  <label>{{i18n "discussion_bridge.admin.search_tags"}}<input
                      value={{this.publicationTagQuery}}
                      {{on "input" this.searchPublicationTags}}
                    /></label>
                  {{#each this.publicationTags as |tag|}}
                    <div class="discussion-bridge-direction-option">
                      <label><input
                          type="checkbox"
                          checked={{tag.selected}}
                          {{on "change" (fn this.togglePublicationTag tag.id)}}
                        />{{tag.name}}</label>
                    </div>
                  {{/each}}
                {{/unless}}
                <label class="discussion-bridge-checkbox-setting"><input
                    type="checkbox"
                    checked={{this.publicationIncludeUnlisted}}
                    {{on "change" this.updatePublicationIncludeUnlisted}}
                  /><span><strong>{{i18n
                        "discussion_bridge.admin.publication_include_unlisted"
                      }}</strong><small>{{i18n
                        "discussion_bridge.admin.publication_include_unlisted_description"
                      }}</small></span></label>
              {{/if}}
            </fieldset>
          {{/if}}
          <label class="discussion-bridge-checkbox-setting">
            <input
              type="checkbox"
              aria-label={{i18n "discussion_bridge.admin.generate_topic_toc"}}
              checked={{this.generateTopicToc}}
              {{on "change" this.updateGenerateTopicToc}}
            />
            <span><strong>{{i18n
                  "discussion_bridge.admin.generate_topic_toc"
                }}</strong><small>{{i18n
                  "discussion_bridge.admin.generate_topic_toc_description"
                }}</small></span>
          </label>
        {{else if (eq this.editingTab "authors")}}
          <section class="discussion-bridge-authors-panel">
            <p>{{i18n "discussion_bridge.admin.authors_description"}}</p>
            <label>{{i18n "discussion_bridge.admin.authorship_mode"}}
              <select {{on "change" this.updateAuthorshipMode}}>
                <option
                  value="fixed"
                  selected={{eq this.authorshipMode "fixed"}}
                >{{i18n "discussion_bridge.admin.authorship_fixed"}}</option>
                <option
                  value="mapped"
                  selected={{eq this.authorshipMode "mapped"}}
                >{{i18n "discussion_bridge.admin.authorship_mapped"}}</option>
              </select>
            </label>
            <label>{{i18n "discussion_bridge.admin.fallback_author"}}<input
                value={{this.authorUsername}}
                {{on "input" this.updateAuthorUsername}}
                placeholder={{i18n
                  "discussion_bridge.admin.topic_author_default"
                }}
              /></label>
            <label>{{i18n "discussion_bridge.admin.unmapped_author_policy"}}
              <select {{on "change" this.updateUnmappedAuthorPolicy}}>
                <option
                  value="fallback"
                  selected={{eq this.unmappedAuthorPolicy "fallback"}}
                >{{i18n "discussion_bridge.admin.unmapped_fallback"}}</option>
                <option
                  value="hold"
                  selected={{eq this.unmappedAuthorPolicy "hold"}}
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
                {{#each @model.content_connections as |candidate|}}
                  {{#if (eq candidate.id this.editingConnectionId)}}
                    {{#each candidate.source_authors as |sourceAuthor|}}
                      <tr>
                        <td><strong>{{sourceAuthor.display_name}}</strong><br
                          /><code>{{sourceAuthor.source_author_id}}</code></td>
                        <td>{{#if sourceAuthor.profile_url}}<a
                              href={{sourceAuthor.profile_url}}
                              target="_blank"
                              rel="noopener noreferrer"
                            >{{sourceAuthor.profile_url}}</a>{{else}}—{{/if}}</td>
                        <td><input
                            value={{sourceAuthor.discourse_username}}
                            {{on
                              "input"
                              (fn this.updateSourceMapping sourceAuthor)
                            }}
                            placeholder={{i18n
                              "discussion_bridge.admin.unmapped"
                            }}
                          /></td>
                        <td><DButton
                            @label="discussion_bridge.admin.save_mapping"
                            @action={{this.saveAuthorMapping}}
                            @actionParam={{sourceAuthor}}
                          /></td>
                      </tr>
                    {{else}}
                      <tr><td colspan="4">{{i18n
                            "discussion_bridge.admin.no_source_authors"
                          }}</td></tr>
                    {{/each}}
                  {{/if}}
                {{/each}}
              </tbody>
            </table>
          </section>
        {{else}}
          <section class="discussion-bridge-mapping-panel">
            {{#if this.editingConnection.platform_catalog_revision}}
              <p>{{i18n
                  "discussion_bridge.admin.destination_mapping_description"
                }}</p>
              <dl>
                <dt>{{i18n "discussion_bridge.admin.platform_catalog"}}</dt>
                <dd><code
                  >{{this.editingConnection.platform_catalog_revision}}</code></dd>
                <dt>{{i18n "discussion_bridge.admin.adapter_identity"}}</dt>
                <dd><code
                  >{{this.editingConnection.platform_catalog_adapter_id}}</code>
                  ·
                  <code
                  >{{this.editingConnection.platform_catalog_adapter_version}}</code></dd>
                <dt>{{i18n "discussion_bridge.admin.last_seen"}}</dt>
                <dd>{{this.displayTimestamp
                    this.editingConnection.platform_catalog_observed_at
                  }}</dd>
              </dl>

              {{#if this.platformInventoryIncomplete}}
                <div class="alert alert-error">
                  {{i18n
                    "discussion_bridge.admin.platform_inventory_incomplete"
                    authors=this.platformInventory.authors_observed
                    terms=this.platformInventory.terms_observed
                  }}
                </div>
              {{/if}}

              <label>{{i18n "discussion_bridge.admin.presentation_mode"}}
                <select {{on "change" this.updatePresentationMode}}>
                  {{#each this.platformPresentationModes as |mode|}}
                    <option
                      value={{mode}}
                      selected={{eq mode this.presentationMode}}
                    >{{this.displayToken mode}}</option>
                  {{/each}}
                </select>
              </label>

              <label>{{i18n
                  "discussion_bridge.admin.destination_authorship_policy"
                }}
                <select
                  {{on "change" this.updateDestinationAuthorshipPolicy}}
                >
                  <option
                    value="service_author"
                    selected={{eq
                      this.destinationAuthorshipPolicy
                      "service_author"
                    }}
                  >{{i18n
                      "discussion_bridge.admin.destination_service_author"
                    }}</option>
                  <option
                    value="fixed"
                    selected={{eq this.destinationAuthorshipPolicy "fixed"}}
                  >{{i18n
                      "discussion_bridge.admin.destination_fixed_author"
                    }}</option>
                </select>
              </label>
              {{#if (eq this.destinationAuthorshipPolicy "fixed")}}
                <label>{{i18n "discussion_bridge.admin.destination_author"}}
                  <select
                    required
                    {{on "change" this.updateDestinationAuthor}}
                  >
                    <option value="">{{i18n
                        "discussion_bridge.admin.select_destination_author"
                      }}</option>
                    {{#each this.platformAuthors as |author|}}
                      <option
                        value={{author.id}}
                        selected={{eq author.id this.destinationAuthorId}}
                      >{{author.label}}</option>
                    {{/each}}
                  </select>
                </label>
              {{/if}}

              <label>{{i18n "discussion_bridge.admin.destination_url_policy"}}
                <select {{on "change" this.updateDestinationSlugPolicy}}>
                  <option
                    value="platform_default"
                    selected={{eq
                      this.destinationSlugPolicy
                      "platform_default"
                    }}
                  >{{i18n
                      "discussion_bridge.admin.url_platform_default"
                    }}</option>
                  <option
                    value="source_title"
                    selected={{eq this.destinationSlugPolicy "source_title"}}
                  >{{i18n "discussion_bridge.admin.url_source_title"}}</option>
                  <option
                    value="topic_id"
                    selected={{eq this.destinationSlugPolicy "topic_id"}}
                  >{{i18n "discussion_bridge.admin.url_topic_id"}}</option>
                </select>
              </label>

              <h4>{{i18n
                  "discussion_bridge.admin.category_destination_mapping"
                }}</h4>
              {{#each this.mappingSourceCategories as |category|}}
                <label>{{category.path}}
                  <select
                    {{on
                      "change"
                      (fn this.updateDestinationCategory category.id)
                    }}
                  >
                    <option value="">{{i18n
                        "discussion_bridge.admin.hold_unmapped"
                      }}</option>
                    {{#each this.platformContainers as |container|}}
                      <option
                        value={{container.id}}
                        selected={{eq category.destinationId container.id}}
                      >{{container.label}}
                        ·
                        {{this.displayToken container.kind}}{{#if
                          container.path
                        }} · {{container.path}}{{/if}}</option>
                    {{/each}}
                  </select>
                </label>
              {{/each}}

              <label>{{i18n "discussion_bridge.admin.unmapped_category_policy"}}
                <select {{on "change" this.updateUnmappedCategoryPolicy}}>
                  <option
                    value="hold"
                    selected={{eq this.unmappedCategoryPolicy "hold"}}
                  >{{i18n "discussion_bridge.admin.hold_unmapped"}}</option>
                  <option
                    value="default"
                    selected={{eq this.unmappedCategoryPolicy "default"}}
                  >{{i18n
                      "discussion_bridge.admin.use_default_destination"
                    }}</option>
                </select>
              </label>
              {{#if (eq this.unmappedCategoryPolicy "default")}}
                <label>{{i18n "discussion_bridge.admin.default_destination"}}
                  <select
                    required
                    {{on "change" this.updateDefaultDestinationContainer}}
                  >
                    <option value="">{{i18n
                        "discussion_bridge.admin.select_destination"
                      }}</option>
                    {{#each this.platformContainers as |container|}}
                      <option
                        value={{container.id}}
                        selected={{eq
                          container.id
                          this.defaultDestinationContainerId
                        }}
                      >{{container.label}}
                        ·
                        {{this.displayToken container.kind}}</option>
                    {{/each}}
                  </select>
                </label>
              {{/if}}

              <h4>{{i18n
                  "discussion_bridge.admin.tag_destination_mapping"
                }}</h4>
              <label>{{i18n "discussion_bridge.admin.search_tags"}}<input
                  value={{this.publicationTagQuery}}
                  {{on "input" this.searchPublicationTags}}
                /></label>
              {{#each this.mappingSourceTags as |tag|}}
                <label>{{tag.name}}
                  <select {{on "change" (fn this.updateDestinationTag tag.id)}}>
                    <option value="">{{i18n
                        "discussion_bridge.admin.omit_unmapped"
                      }}</option>
                    {{#each this.platformTaxonomyTerms as |term|}}
                      <option
                        value={{term.value}}
                        selected={{eq tag.destinationValue term.value}}
                      >{{term.label}}</option>
                    {{/each}}
                  </select>
                </label>
              {{/each}}
              <label>{{i18n "discussion_bridge.admin.unmapped_tag_policy"}}
                <select {{on "change" this.updateUnmappedTagPolicy}}>
                  <option
                    value="omit"
                    selected={{eq this.unmappedTagPolicy "omit"}}
                  >{{i18n "discussion_bridge.admin.omit_unmapped"}}</option>
                  <option
                    value="hold"
                    selected={{eq this.unmappedTagPolicy "hold"}}
                  >{{i18n "discussion_bridge.admin.hold_unmapped"}}</option>
                </select>
              </label>

              <DButton
                @label="discussion_bridge.admin.preview_publication"
                @action={{this.loadPublicationPreview}}
              />
              {{#if this.publicationPreview}}
                <p class="discussion-bridge-publication-preview">
                  <strong>{{i18n
                      "discussion_bridge.admin.preview_result"
                    }}</strong>
                  {{this.publicationPreview.ready}}
                  {{i18n "discussion_bridge.admin.ready"}}
                  ·
                  {{this.publicationPreview.held}}
                  {{i18n "discussion_bridge.admin.held"}}
                  {{#if this.publicationPreview.truncated}}
                    ·
                    {{i18n "discussion_bridge.admin.preview_truncated"}}{{/if}}
                </p>
                {{#each this.publicationPreview.held_samples as |sample|}}
                  <p><a href={{sample.topic_url}}>{{sample.title}}</a>
                    ·
                    {{#each sample.reasons as |reason|}}{{this.displayToken
                        reason
                      }}
                    {{/each}}</p>
                {{/each}}
              {{/if}}
            {{else}}
              <p>{{i18n
                  "discussion_bridge.admin.catalog_required_for_mapping"
                }}</p>
            {{/if}}
          </section>
        {{/if}}
        <div class="discussion-bridge-add-connection__actions">
          <DButton
            @type="submit"
            @label={{if
              this.editingConnectionId
              "discussion_bridge.admin.save_connection"
              "discussion_bridge.admin.add_connection"
            }}
            class="btn-primary"
          />
          {{#if this.editingConnectionId}}
            <DButton
              @label="discussion_bridge.admin.cancel"
              @action={{this.cancelEdit}}
            />
          {{/if}}
        </div>
      </form>
    </section>
  </template>
}
