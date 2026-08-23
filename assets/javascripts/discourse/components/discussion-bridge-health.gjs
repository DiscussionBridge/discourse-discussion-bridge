import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

export default <template>
  <section class="discussion-bridge-health">
    <DPageSubheader
      @titleLabel={{i18n "discussion_bridge.admin.health_title"}}
      @descriptionLabel={{i18n "discussion_bridge.admin.health_description"}}
    />

    <div class="discussion-bridge-health__readiness">
      <strong>
        {{if
          @status.readiness.controlled_creation_ready
          (i18n "discussion_bridge.admin.ready")
          (i18n "discussion_bridge.admin.needs_attention")
        }}
      </strong>
      {{#if @status.readiness.blockers.length}}
        <ul>
          {{#each @status.readiness.blockers as |blocker|}}
            <li><code>{{blocker}}</code></li>
          {{/each}}
        </ul>
      {{else}}
        <p>{{i18n "discussion_bridge.admin.no_blockers"}}</p>
      {{/if}}
    </div>

    <div class="discussion-bridge-health__readiness">
      <strong>{{i18n "discussion_bridge.admin.full_interactive_readiness"}}:</strong>
      <strong>
        {{if
          @status.readiness.full_interactive_ready
          (i18n "discussion_bridge.admin.ready")
          (i18n "discussion_bridge.admin.needs_attention")
        }}
      </strong>
      {{#if @status.readiness.full_interactive_blockers.length}}
        <ul>
          {{#each @status.readiness.full_interactive_blockers as |blocker|}}
            <li><code>{{blocker}}</code></li>
          {{/each}}
        </ul>
      {{else}}
        <p>{{i18n "discussion_bridge.admin.full_interactive_ready"}}</p>
      {{/if}}
    </div>

    <div class="discussion-bridge-health__grid">
      <section>
        <h3>{{i18n "discussion_bridge.admin.features"}}</h3>
        <dl>
          <dt>{{i18n "discussion_bridge.admin.endpoint"}}</dt>
          <dd>{{if
              @status.features.endpoint_enabled
              (i18n "discussion_bridge.admin.enabled")
              (i18n "discussion_bridge.admin.disabled")
            }}</dd>
          <dt>{{i18n "discussion_bridge.admin.comments_only"}}</dt>
          <dd>{{if
              @status.features.comments_only_full_interactive
              (i18n "discussion_bridge.admin.enabled")
              (i18n "discussion_bridge.admin.disabled")
            }}</dd>
          <dt>{{i18n "discussion_bridge.admin.zero_touch"}}</dt>
          <dd>{{if
              @status.features.core_zero_touch_compatibility
              (i18n "discussion_bridge.admin.enabled")
              (i18n "discussion_bridge.admin.disabled")
            }}</dd>
        </dl>
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.connection"}}</h3>
        <dl>
          <dt>{{i18n "discussion_bridge.admin.credential"}}</dt>
          <dd>{{if
              @status.connection.credential_configured
              (i18n "discussion_bridge.admin.configured")
              (i18n "discussion_bridge.admin.missing")
            }}</dd>
          <dt>{{i18n "discussion_bridge.admin.trusted_origins"}}</dt>
          <dd>
            <span class="discussion-bridge-health__value-list">
              {{#each @status.connection.trusted_origins as |origin|}}
                <code>{{origin}}</code>
              {{else}}
                {{i18n "discussion_bridge.admin.missing"}}
              {{/each}}
            </span>
          </dd>
        </dl>
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.operating_identity"}}</h3>
        <p>
          {{#if @status.operating_identity.found}}
            <strong>{{@status.operating_identity.username}}</strong>
            (ID
            {{@status.operating_identity.id}})
          {{else}}
            {{i18n "discussion_bridge.admin.missing"}}
          {{/if}}
        </p>
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.forum_authority"}}</h3>
        <dl>
          <dt>{{i18n "discussion_bridge.admin.category"}}</dt>
          <dd>
            {{#if @status.forum_authority.category_name}}
              {{@status.forum_authority.category_name}}
            {{else}}
              {{i18n "discussion_bridge.admin.missing"}}
            {{/if}}
          </dd>
          <dt>{{i18n "discussion_bridge.admin.tags"}}</dt>
          <dd>
            {{#each @status.forum_authority.configured_tags as |tag|}}
              <code>{{tag}}</code>
            {{else}}
              —
            {{/each}}
          </dd>
        </dl>
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.lane_policies"}}</h3>
        {{#if @status.lane_policies.configured}}
          <p><strong>{{@status.lane_policies.count}}</strong>
            {{i18n "discussion_bridge.admin.configured_lanes"}}</p>
          <p>
            {{#each @status.lane_policies.lanes as |lane|}}
              <code>{{lane}}</code>
            {{/each}}
          </p>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.global_policy_active"}}</p>
        {{/if}}
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.mappings"}}</h3>
        <dl>
          <dt>{{i18n "discussion_bridge.admin.total"}}</dt><dd
          >{{@status.mappings.total}}</dd>
          <dt>{{i18n "discussion_bridge.admin.complete"}}</dt><dd
          >{{@status.mappings.complete}}</dd>
          <dt>{{i18n "discussion_bridge.admin.reserved"}}</dt><dd
          >{{@status.mappings.reserved}}</dd>
          <dt>{{i18n "discussion_bridge.admin.failed"}}</dt><dd
          >{{@status.mappings.failed}}</dd>
          <dt>{{i18n "discussion_bridge.admin.system_authored"}}</dt><dd
          >{{@status.mappings.system_authored}}</dd>
        </dl>
      </section>

      <section>
        <h3>{{i18n "discussion_bridge.admin.audits"}}</h3>
        <p><strong>{{@status.audits.total}}</strong>
          {{i18n "discussion_bridge.admin.total"}}</p>
      </section>
    </div>
  </section>
</template>
