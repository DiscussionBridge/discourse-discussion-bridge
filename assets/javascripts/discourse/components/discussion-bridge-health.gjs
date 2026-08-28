import DPageSubheader from "discourse/ui-kit/d-page-subheader";
import { i18n } from "discourse-i18n";

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

    </header>

    <DPageSubheader
      @titleLabel={{i18n "discussion_bridge.admin.overview_title"}}
      @descriptionLabel={{i18n "discussion_bridge.admin.health_description"}}
    />

    <div class="discussion-bridge-health__summary">
      <section class="discussion-bridge-health__metric">
        <span>{{i18n "discussion_bridge.admin.plugin_status"}}</span>
        <strong class="discussion-bridge-health__metric-value">
          {{if
            @status.features.plugin_enabled
            (i18n "discussion_bridge.admin.enabled")
            (i18n "discussion_bridge.admin.disabled")
          }}
        </strong>
      </section>
      <section class="discussion-bridge-health__metric">
        <span>{{i18n "discussion_bridge.admin.companion_mappings"}}</span>
        <strong class="discussion-bridge-health__metric-value">
          {{@status.mappings.total}}
        </strong>
      </section>
      <section class="discussion-bridge-health__metric">
        <span>{{i18n "discussion_bridge.admin.completed_mappings"}}</span>
        <strong class="discussion-bridge-health__metric-value">
          {{@status.mappings.complete}}
        </strong>
      </section>
      <section class="discussion-bridge-health__metric">
        <span>{{i18n "discussion_bridge.admin.failed_mappings"}}</span>
        <strong class="discussion-bridge-health__metric-value">
          {{@status.mappings.failed}}
        </strong>
      </section>
      <section class="discussion-bridge-health__metric">
        <span>{{i18n "discussion_bridge.admin.audit_events"}}</span>
        <strong class="discussion-bridge-health__metric-value">
          {{@status.audits.total}}
        </strong>
      </section>
    </div>

    <div class="discussion-bridge-health__readiness-grid">
      <section
        class="discussion-bridge-health__readiness"
        data-state={{if
          @status.readiness.controlled_creation_ready
          "ready"
          "attention"
        }}
      >
        <div class="discussion-bridge-health__readiness-heading">
          <strong>{{i18n "discussion_bridge.admin.controlled_creation"}}</strong>
          <span>
            {{if
              @status.readiness.controlled_creation_ready
              (i18n "discussion_bridge.admin.ready")
              (i18n "discussion_bridge.admin.needs_attention")
            }}
          </span>
        </div>
        {{#if @status.readiness.blockers.length}}
          <ul>
            {{#each @status.readiness.blockers as |blocker|}}
              <li><code>{{blocker}}</code></li>
            {{/each}}
          </ul>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.no_blockers"}}</p>
        {{/if}}
      </section>

      <section
        class="discussion-bridge-health__readiness"
        data-state={{if
          @status.readiness.full_interactive_ready
          "ready"
          "attention"
        }}
      >
        <div class="discussion-bridge-health__readiness-heading">
          <strong>{{i18n "discussion_bridge.admin.full_interactive_readiness"}}</strong>
          <span>
            {{if
              @status.readiness.full_interactive_ready
              (i18n "discussion_bridge.admin.ready")
              (i18n "discussion_bridge.admin.needs_attention")
            }}
          </span>
        </div>
        {{#if @status.readiness.full_interactive_blockers.length}}
          <ul>
            {{#each @status.readiness.full_interactive_blockers as |blocker|}}
              <li><code>{{blocker}}</code></li>
            {{/each}}
          </ul>
        {{else}}
          <p>{{i18n "discussion_bridge.admin.full_interactive_ready"}}</p>
        {{/if}}
      </section>
    </div>

    <h3 class="discussion-bridge-health__details-heading">
      {{i18n "discussion_bridge.admin.configuration_details"}}
    </h3>

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
    </div>
  </section>
</template>
