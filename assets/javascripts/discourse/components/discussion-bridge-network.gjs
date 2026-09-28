import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeNetwork extends Component {
  @tracked state;
  @tracked connections = [];
  @tracked working = false;
  @tracked notice = "";
  @tracked confirmationForumId = "";
  @tracked contentConnectionId = "";
  @tracked peerName = "";
  @tracked peerForumId = "";
  @tracked peerForumName = "";
  @tracked peerOrigin = "";
  @tracked peerConnectionId = "";
  @tracked peerSecret = "";
  @tracked relationship = "hub_to_spoke";

  constructor(owner, args) {
    super(owner, args);
    this.state = args.model;
    void this.reload();
  }

  @action
  updateConfirmation(event) {
    this.confirmationForumId = event.target.value;
  }

  @action
  updateConnection(event) {
    this.contentConnectionId = event.target.value;
  }

  @action
  updatePeerName(event) {
    this.peerName = event.target.value;
  }

  @action
  updatePeerForumId(event) {
    this.peerForumId = event.target.value;
  }

  @action
  updatePeerForumName(event) {
    this.peerForumName = event.target.value;
  }

  @action
  updatePeerOrigin(event) {
    this.peerOrigin = event.target.value;
  }

  @action
  updatePeerConnectionId(event) {
    this.peerConnectionId = event.target.value;
  }

  @action
  updatePeerSecret(event) {
    this.peerSecret = event.target.value;
  }

  @action
  updateRelationship(event) {
    this.relationship = event.target.value;
  }

  @action
  async enableNetwork() {
    await this.mutate("/discussion-bridge/admin/network/enable.json", {
      type: "POST",
    });
    this.notice = i18n("discussion_bridge.admin.network_enabled_notice");
  }

  @action
  async disableNetwork() {
    await this.mutate("/discussion-bridge/admin/network/disable.json", {
      type: "POST",
    });
    this.notice = i18n("discussion_bridge.admin.network_disabled_notice");
  }

  @action
  async rotateIdentity(event) {
    event.preventDefault();
    await this.mutate("/discussion-bridge/admin/network/rotate.json", {
      type: "POST",
      data: { confirmation_forum_id: this.confirmationForumId },
    });
    this.confirmationForumId = "";
    this.notice = i18n("discussion_bridge.admin.network_rotated_notice");
  }

  @action
  async createPeer(event) {
    event.preventDefault();
    await this.mutate("/discussion-bridge/admin/network/peers.json", {
      type: "POST",
      data: {
        network_peer: {
          content_connection_id: this.contentConnectionId,
          name: this.peerName,
          remote_forum_id: this.peerForumId,
          remote_forum_name: this.peerForumName,
          remote_origin: this.peerOrigin,
          remote_connection_id: this.peerConnectionId,
          remote_secret: this.peerSecret,
          relationship: this.relationship,
          enabled: true,
        },
      },
    });
    this.peerSecret = "";
    this.notice = i18n("discussion_bridge.admin.network_peer_added_notice");
  }

  @action
  async disablePeer(peer) {
    await this.mutate(
      "/discussion-bridge/admin/network/peers/" + peer.id + "/disable.json",
      { type: "POST" }
    );
    this.notice = i18n("discussion_bridge.admin.network_peer_disabled_notice");
  }

  async reload() {
    this.working = true;
    try {
      const [state, connections] = await Promise.all([
        ajax("/discussion-bridge/admin/network.json"),
        ajax("/discussion-bridge/admin/content-connections.json"),
      ]);
      this.state = state;
      this.connections = connections.content_connections.filter(
        (connection) =>
          connection.platform === "discourse" &&
          connection.network_enabled &&
          connection.allowed_directions.includes("to_discourse")
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.working = false;
    }
  }

  async mutate(url, options) {
    this.working = true;
    this.notice = "";
    try {
      await ajax(url, options);
      await this.reload();
    } catch (error) {
      popupAjaxError(error);
      throw error;
    } finally {
      this.working = false;
    }
  }

  display(value) {
    return value?.replaceAll("_", " ") || "—";
  }

  <template>
    <section class="discussion-bridge-network">
      <DPageSubheader
        @titleLabel={{i18n "discussion_bridge.admin.network_nav"}}
        @descriptionLabel={{i18n "discussion_bridge.admin.network_description"}}
      />
      {{#if this.notice}}<p
          class="alert alert-success"
        >{{this.notice}}</p>{{/if}}
      {{#if this.state}}
        <section class="discussion-bridge-network__panel">
          <h3>{{i18n "discussion_bridge.admin.network_identity"}}</h3>
          {{#if this.state.network_identity}}
            <dl><div><dt>{{i18n
                    "discussion_bridge.admin.network_forum_id"
                  }}</dt><dd><code
                  >{{this.state.network_identity.forum_id}}</code></dd></div><div
              ><dt>{{i18n "discussion_bridge.admin.status"}}</dt><dd>{{if
                    this.state.network_identity.ready
                    (i18n "discussion_bridge.admin.ready")
                    (i18n "discussion_bridge.admin.disabled")
                  }}</dd></div><div><dt>{{i18n
                    "discussion_bridge.admin.network_site_origin"
                  }}</dt><dd
                >{{this.state.network_identity.site_origin}}</dd></div></dl>
            <DButton
              @label={{if
                this.state.network_identity.enabled
                "discussion_bridge.admin.network_disable"
                "discussion_bridge.admin.network_enable"
              }}
              @action={{if
                this.state.network_identity.enabled
                this.disableNetwork
                this.enableNetwork
              }}
              @disabled={{this.working}}
            />
            <form {{on "submit" this.rotateIdentity}}><label>{{i18n
                  "discussion_bridge.admin.network_rotate_confirmation"
                }}<input
                  required
                  value={{this.confirmationForumId}}
                  {{on "input" this.updateConfirmation}}
                /></label><DButton
                @type="submit"
                @label="discussion_bridge.admin.network_rotate"
                @disabled={{this.working}}
              /></form>
          {{else}}
            <p>{{i18n "discussion_bridge.admin.network_default_off"}}</p>
            <DButton
              @label="discussion_bridge.admin.network_enable"
              @action={{this.enableNetwork}}
              @disabled={{this.working}}
            />
          {{/if}}
        </section>

        <section class="discussion-bridge-network__panel">
          <h3>{{i18n "discussion_bridge.admin.network_peers"}}</h3>
          <ul>{{#each this.state.network_peers as |peer|}}<li><strong
                >{{peer.name}}</strong>
                ·
                {{this.display peer.relationship}}
                ·
                <code>{{peer.remote_forum_id}}</code>
                ·
                {{if
                  peer.operational
                  (i18n "discussion_bridge.admin.ready")
                  (i18n "discussion_bridge.admin.disabled")
                }}
                {{#if peer.enabled}}<DButton
                    @label="discussion_bridge.admin.disable"
                    @action={{fn this.disablePeer peer}}
                    @disabled={{this.working}}
                  />{{/if}}</li>{{else}}<li>{{i18n
                  "discussion_bridge.admin.network_no_peers"
                }}</li>{{/each}}</ul>
        </section>

        {{#if this.state.network_identity.ready}}
          <section class="discussion-bridge-network__panel">
            <h3>{{i18n "discussion_bridge.admin.network_add_peer"}}</h3>
            <form {{on "submit" this.createPeer}}>
              <label>{{i18n "discussion_bridge.admin.connection"}}<select
                  required
                  {{on "change" this.updateConnection}}
                ><option value=""></option>{{#each
                    this.connections
                    as |connection|
                  }}<option
                      value={{connection.id}}
                    >{{connection.name}}</option>{{/each}}</select></label>
              <label>{{i18n "discussion_bridge.admin.network_peer_name"}}<input
                  required
                  value={{this.peerName}}
                  {{on "input" this.updatePeerName}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_peer_forum_id"
                }}<input
                  required
                  value={{this.peerForumId}}
                  {{on "input" this.updatePeerForumId}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_peer_forum_name"
                }}<input
                  required
                  value={{this.peerForumName}}
                  {{on "input" this.updatePeerForumName}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_peer_origin"
                }}<input
                  required
                  type="url"
                  value={{this.peerOrigin}}
                  {{on "input" this.updatePeerOrigin}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_peer_connection_id"
                }}<input
                  required
                  value={{this.peerConnectionId}}
                  {{on "input" this.updatePeerConnectionId}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_peer_secret"
                }}<input
                  required
                  type="password"
                  value={{this.peerSecret}}
                  {{on "input" this.updatePeerSecret}}
                /></label>
              <label>{{i18n
                  "discussion_bridge.admin.network_relationship"
                }}<select {{on "change" this.updateRelationship}}><option
                    value="hub_to_spoke"
                  >{{i18n
                      "discussion_bridge.admin.network_hub_to_spoke"
                    }}</option><option value="spoke_to_hub">{{i18n
                      "discussion_bridge.admin.network_spoke_to_hub"
                    }}</option></select></label>
              <DButton
                @type="submit"
                @label="discussion_bridge.admin.network_add_peer"
                @disabled={{this.working}}
              />
            </form>
          </section>
        {{/if}}
      {{/if}}
    </section>
  </template>
}
