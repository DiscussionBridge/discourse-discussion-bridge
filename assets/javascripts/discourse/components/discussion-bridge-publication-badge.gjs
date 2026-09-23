import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgePublicationBadge extends Component {
  get summary() {
    const summary =
      this.args.outletArgs?.topic?.discussion_bridge_publication_summary;
    const validStates = new Set([
      "published",
      "not_published",
      "partial",
      "pending",
      "attention",
    ]);
    const countKeys = ["published", "total", "pending", "attention"];

    if (
      !summary ||
      !validStates.has(summary.state) ||
      !countKeys.every((key) => Number.isInteger(summary[key]))
    ) {
      return null;
    }

    return summary;
  }

  get label() {
    const summary = this.summary;
    if (!summary) {
      return null;
    }
    if (summary.attention > 0) {
      return i18n("discussion_bridge.publication_badge.attention");
    }
    if (summary.pending > 0) {
      return i18n("discussion_bridge.publication_badge.syncing", {
        published: summary.published,
        total: summary.total,
      });
    }
    if (summary.state === "published") {
      return i18n("discussion_bridge.publication_badge.published");
    }
    if (summary.state === "not_published") {
      return i18n("discussion_bridge.publication_badge.not_published");
    }

    return i18n("discussion_bridge.publication_badge.partial", {
      published: summary.published,
      total: summary.total,
    });
  }

  get title() {
    return i18n("discussion_bridge.publication_badge.detail", {
      published: this.summary.published,
      total: this.summary.total,
      pending: this.summary.pending,
      attention: this.summary.attention,
    });
  }

  <template>
    {{#if this.summary}}
      <span
        class="discussion-bridge-publication-badge"
        data-state={{this.summary.state}}
        title={{this.title}}
      >
        {{this.label}}
      </span>
    {{/if}}
  </template>
}
