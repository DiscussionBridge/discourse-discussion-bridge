import DiscussionBridgeConnections from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-connections";

export default <template>
  <DiscussionBridgeConnections
    @model={{@controller.model}}
    @returnTo={{@controller.return_to}}
  />
</template>
