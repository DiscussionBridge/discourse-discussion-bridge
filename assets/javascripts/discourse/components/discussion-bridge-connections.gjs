import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { array, concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import DiscussionBridgeConnectionForm from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-connection-form";
import focusTarget from "discourse/plugins/discourse-discussion-bridge/discourse/modifiers/discussion-bridge-focus";

const WORKSPACE = "adminPlugins.show.discussion-bridge-connection";

export default class DiscussionBridgeConnections extends Component {
  @service router;
  @service dialog;

  @tracked issuedSecret = null;
  @tracked issuedConnectionId = null;
  @tracked copiedCredential = null;

  @action
  showCredential(secret, publicId) {
    this.issuedSecret = secret;
    this.issuedConnectionId = publicId;
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
  async toggleConnection(connection) {
    if (connection.enabled) {
      const confirmed = await this.dialog.yesNoConfirm({
        message: i18n("discussion_bridge.admin.disable_connection_confirm"),
      });
      if (!confirmed) {
        return;
      }
    }
    try {
      await ajax(
        `/discussion-bridge/admin/content-connections/${connection.id}.json`,
        {
          type: "PUT",
          data: { content_connection: { enabled: !connection.enabled } },
        }
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
        { type: "POST" }
      );
      this.issuedSecret = result.secret;
      this.issuedConnectionId = connection.public_id;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  displayToken(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  adapterVerified(connection) {
    return Boolean(
      connection.adapter_id &&
      connection.adapter_version &&
      connection.last_seen_at
    );
  }

  displayTimestamp(value) {
    return value ? new Date(value).toLocaleString() : "—";
  }

  <template>
    <section class="discussion-bridge-connections">
      <DPageSubheader
        @descriptionLabel={{i18n
          "discussion_bridge.admin.connections_description"
        }}
        @titleLabel={{i18n "discussion_bridge.admin.connections_title"}}
      />

      {{#if this.issuedSecret}}
        <section class="discussion-bridge-secret" role="status">
          <strong>{{i18n "discussion_bridge.admin.secret_shown_once"}}</strong>
          <div class="discussion-bridge-secret__row">
            <span>{{i18n "discussion_bridge.admin.connection_id"}}</span>
            <code>{{this.issuedConnectionId}}</code>
            <button
              class="btn btn-default"
              type="button"
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
              class="btn btn-default"
              type="button"
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
              >{{this.displayToken connection.health}}</span>
            </header>
            <dl>
              <dt>{{i18n "discussion_bridge.admin.directions"}}</dt><dd>{{#each
                  connection.allowed_directions
                  as |direction|
                }}<span>{{this.displayToken direction}}</span>{{/each}}</dd>
              <dt>{{i18n "discussion_bridge.admin.origins"}}</dt><dd>{{#each
                  connection.allowed_origins
                  as |origin|
                }}<code>{{origin}}</code>{{/each}}</dd>
            </dl>
            <details>
              <summary>{{i18n
                  "discussion_bridge.admin.connection_details"
                }}</summary>
              <dl>
                <dt>{{i18n "discussion_bridge.admin.bridge_records"}}</dt><dd
                >{{connection.bridge_record_count}}</dd>
                <dt>{{i18n "discussion_bridge.admin.connection_id"}}</dt><dd
                ><code>{{connection.public_id}}</code></dd>
                <dt>{{i18n "discussion_bridge.admin.topic_author"}}</dt><dd
                ><code>{{connection.author_username}}</code>{{#unless
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
                <dt>{{i18n "discussion_bridge.admin.category_route"}}</dt><dd
                >{{connection.category_route.category_name}}
                  <small>({{if
                      (eq connection.category_route.source "connection")
                      (i18n "discussion_bridge.admin.connection_route")
                      (i18n "discussion_bridge.admin.forum_fallback")
                    }})</small></dd>
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
              </dl>
            </details>
            <div class="discussion-bridge-actions">
              <LinkTo
                class="btn btn-default"
                @models={{array connection.id "general"}}
                @route={{WORKSPACE}}
                {{focusTarget (eq @returnTo (concat connection.id))}}
              >{{i18n "discussion_bridge.admin.manage"}}</LinkTo>
              <LinkTo
                class="btn btn-default"
                @models={{array connection.id "publication"}}
                @route={{WORKSPACE}}
              >{{i18n "discussion_bridge.admin.cms.configure"}}</LinkTo>
              <DButton
                @action={{this.toggleConnection}}
                @actionParam={{connection}}
                @label={{if
                  connection.enabled
                  "discussion_bridge.admin.disable"
                  "discussion_bridge.admin.enable"
                }}
              />
              <DButton
                @action={{this.rotateSecret}}
                @actionParam={{connection}}
                @label="discussion_bridge.admin.rotate_secret"
              />
            </div>
          </article>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.no_connections"}}</p>
        {{/each}}
      </div>

      <DiscussionBridgeConnectionForm
        @model={{@model}}
        @onIssuedSecret={{this.showCredential}}
      />
    </section>
  </template>
}
