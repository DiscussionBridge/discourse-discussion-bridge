import DiscussionBridgeHealth from "discourse/plugins/discourse-discussion-bridge/discourse/components/discussion-bridge-health";

export default <template>
  <DiscussionBridgeHealth @status={{@controller.model}} />
</template>
