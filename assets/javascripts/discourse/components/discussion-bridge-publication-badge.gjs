import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgePublicationBadge extends Component {
  get summary() {
    const value =
      this.args.outletArgs?.topic?.discussion_bridge_publication_summary;
    const states = new Set([
      "published",
      "not_published",
      "partial",
      "pending",
      "attention",
    ]);
    const counts = ["published", "total", "pending", "attention", "excluded"];
    if (
      !value ||
      !states.has(value.state) ||
      !counts.every((key) => Number.isInteger(value[key]))
    ) {
      return null;
    }
    return value;
  }

  get label() {
    if (this.summary.attention > 0) {
      return i18n("discussion_bridge.publication_badge.attention");
    }
    if (this.summary.pending > 0) {
      return i18n("discussion_bridge.publication_badge.pending", {
        published: this.summary.published,
        total: this.summary.total,
      });
    }
    if (this.summary.state === "published") {
      return i18n("discussion_bridge.publication_badge.published");
    }
    if (this.summary.state === "not_published") {
      return i18n("discussion_bridge.publication_badge.not_published");
    }
    return i18n("discussion_bridge.publication_badge.partial", {
      published: this.summary.published,
      total: this.summary.total,
    });
  }

  get title() {
    return i18n("discussion_bridge.publication_badge.detail", {
      published: this.summary.published,
      total: this.summary.total,
      pending: this.summary.pending,
      attention: this.summary.attention,
      excluded: this.summary.excluded,
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
