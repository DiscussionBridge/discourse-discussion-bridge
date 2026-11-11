import { array, concat, hash } from "@ember/helper";
import { LinkTo } from "@ember/routing";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import DiscussionBridgeCmsConfiguration from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-cms-configuration";
import DiscussionBridgeConnectionForm from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-connection-form";
import focusTarget from "discourse/plugins/discourse-discussion-bridge/discourse/modifiers/discussion-bridge-focus";

const WORKSPACE = "adminPlugins.show.discussion-bridge-connection";
const CONNECTIONS = "adminPlugins.show.discussion-bridge-connections";

export default <template>
  {{#let @controller.model as |model|}}
    {{#if model.connection}}
      <section class="discussion-bridge-connection-workspace">
        <LinkTo
          @query={{hash return_to=(concat model.connection.id)}}
          @route={{CONNECTIONS}}
        >
          {{i18n "discussion_bridge.admin.back_to_connections"}}
        </LinkTo>
        <h2
          tabindex="-1"
          {{focusTarget (concat model.connection.id ":" model.section)}}
        >{{model.connection.name}}</h2>
        <nav
          aria-label={{i18n "discussion_bridge.admin.connection_settings_tabs"}}
          class="discussion-bridge-connection-tabs"
        >
          <LinkTo
            @models={{array model.connection.id "general"}}
            @route={{WORKSPACE}}
          >
            {{i18n "discussion_bridge.admin.general_tab"}}
          </LinkTo>
          <LinkTo
            @models={{array model.connection.id "authors"}}
            @route={{WORKSPACE}}
          >
            {{i18n "discussion_bridge.admin.authors_tab"}}
          </LinkTo>
          <LinkTo
            @models={{array model.connection.id "publication"}}
            @route={{WORKSPACE}}
          >
            {{i18n "discussion_bridge.admin.cms.configure"}}
          </LinkTo>
        </nav>
        {{#each (array model) key="workspaceKey" as |workspace|}}
          {{#if (eq workspace.section "publication")}}
            <DiscussionBridgeCmsConfiguration
              @categories={{workspace.categories}}
              @connection={{workspace.connection}}
            />
          {{else}}
            <DiscussionBridgeConnectionForm
              @connection={{workspace.connection}}
              @model={{workspace}}
              @section={{workspace.section}}
            />
          {{/if}}
        {{/each}}
      </section>
    {{/if}}
  {{/let}}
</template>
