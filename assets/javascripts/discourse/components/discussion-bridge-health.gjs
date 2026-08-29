import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";
import { eq } from "truth-helpers";

export default <template>
  <section class="discussion-bridge-health">
    <header class="discussion-bridge-health__hero">
      <div class="discussion-bridge-health__identity">
        <span class="discussion-bridge-health__mark" aria-hidden="true">DB</span>
        <div>
          <h2>{{i18n "discussion_bridge.admin.title"}}</h2>
          <p>{{i18n "discussion_bridge.admin.overview_description"}}</p>
        </div>
      </div>
      <span class="discussion-bridge-status" data-state={{@status.product.health}}>
        {{if (eq @status.product.health "healthy") (i18n "discussion_bridge.admin.plugin_healthy") (i18n "discussion_bridge.admin.needs_attention")}}
      </span>
    </header>

    <DPageSubheader
      @titleLabel={{i18n "discussion_bridge.admin.overview_title"}}
      @descriptionLabel={{i18n "discussion_bridge.admin.overview_function"}}
    />

    <div class="discussion-bridge-health__summary" aria-live="polite">
      <section class="discussion-bridge-health__metric"><span>{{i18n "discussion_bridge.admin.content_connections"}}</span><strong>{{@status.metrics.content_connections}}</strong></section>
      <section class="discussion-bridge-health__metric"><span>{{i18n "discussion_bridge.admin.bridge_records"}}</span><strong>{{@status.metrics.bridge_records}}</strong></section>
      <section class="discussion-bridge-health__metric"><span>{{i18n "discussion_bridge.admin.needs_attention"}}</span><strong>{{@status.metrics.needs_attention}}</strong></section>
    </div>

    <div class="discussion-bridge-direction-cards">
      <section>
        <h3>{{i18n "discussion_bridge.admin.to_discourse"}}</h3>
        <span>{{i18n "discussion_bridge.admin.connected_platform"}}</span>
        <strong>{{i18n "discussion_bridge.admin.content_source"}}</strong>
        <div aria-label={{i18n "discussion_bridge.admin.to_discourse"}}>→</div>
        <span>{{i18n "discussion_bridge.admin.discourse"}}</span>
        <strong>{{i18n "discussion_bridge.admin.discussion"}}</strong>
        <p>{{@status.directions.to_discourse}} {{i18n "discussion_bridge.admin.bridge_records"}}</p>
      </section>
      <section>
        <h3>{{i18n "discussion_bridge.admin.from_discourse"}}</h3>
        <span>{{i18n "discussion_bridge.admin.discourse"}}</span>
        <strong>{{i18n "discussion_bridge.admin.content_and_discussion"}}</strong>
        <div aria-label={{i18n "discussion_bridge.admin.from_discourse"}}>→</div>
        <span>{{i18n "discussion_bridge.admin.connected_platform"}}</span>
        <strong>{{i18n "discussion_bridge.admin.presentation"}}</strong>
        <p>{{@status.directions.from_discourse}} {{i18n "discussion_bridge.admin.bridge_records"}}</p>
      </section>
    </div>

    <section class="discussion-bridge-readiness" data-state={{if @status.readiness.ready "ready" "attention"}}>
      <h3>{{i18n "discussion_bridge.admin.readiness"}}</h3>
      {{#if @status.readiness.blockers.length}}
        <ul>{{#each @status.readiness.blockers as |blocker|}}<li><code>{{blocker}}</code></li>{{/each}}</ul>
      {{else}}
        <p>{{i18n "discussion_bridge.admin.no_blockers"}}</p>
      {{/if}}
    </section>

    <section>
      <h3>{{i18n "discussion_bridge.admin.recent_connections"}}</h3>
      <div class="discussion-bridge-connection-grid">
        {{#each @status.connections as |connection|}}
          <article class="discussion-bridge-connection-card">
            <span class="discussion-bridge-platform">{{connection.platform}}</span>
            <h4>{{connection.name}}</h4>
            <p>{{connection.bridge_record_count}} {{i18n "discussion_bridge.admin.bridge_records"}}</p>
          </article>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.no_connections"}}</p>
        {{/each}}
      </div>
    </section>

    <a class="btn btn-default" href="/discussion-bridge/admin/support-bundle.json" download>
      {{i18n "discussion_bridge.admin.download_support_bundle"}}
    </a>
  </section>
</template>
