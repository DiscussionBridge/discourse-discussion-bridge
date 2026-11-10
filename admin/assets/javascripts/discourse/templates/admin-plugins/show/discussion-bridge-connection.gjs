import { array, concat, hash } from "@ember/helper";
import { LinkTo } from "@ember/routing";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import DiscussionBridgeConnectionForm from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-connection-form";
import DiscussionBridgeCmsConfiguration from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-cms-configuration";
import focusTarget from "discourse/plugins/discourse-discussion-bridge/discourse/modifiers/discussion-bridge-focus";

const WORKSPACE = "adminPlugins.show.discussion-bridge-connection";
const CONNECTIONS = "adminPlugins.show.discussion-bridge-connections";

export default <template>
  {{#let @controller.model as |model|}}
    {{#if model.connection}}
      <section class="discussion-bridge-connection-workspace">
        <LinkTo @route={{CONNECTIONS}} @query={{hash return_to=(concat model.connection.id)}}>
          {{i18n "discussion_bridge.admin.back_to_connections"}}
        </LinkTo>
        <h2 tabindex="-1" {{focusTarget (concat model.connection.id ":" model.section)}}>{{model.connection.name}}</h2>
        <nav
          aria-label={{i18n "discussion_bridge.admin.connection_settings_tabs"}}
          class="discussion-bridge-connection-tabs"
        >
          <LinkTo @route={{WORKSPACE}} @models={{array model.connection.id "general"}}>
            {{i18n "discussion_bridge.admin.general_tab"}}
          </LinkTo>
          <LinkTo @route={{WORKSPACE}} @models={{array model.connection.id "authors"}}>
            {{i18n "discussion_bridge.admin.authors_tab"}}
          </LinkTo>
          <LinkTo @route={{WORKSPACE}} @models={{array model.connection.id "publication"}}>
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
              @model={{workspace}}
              @connection={{workspace.connection}}
              @section={{workspace.section}}
            />
          {{/if}}
        {{/each}}
      </section>
    {{/if}}
  {{/let}}
</template>
