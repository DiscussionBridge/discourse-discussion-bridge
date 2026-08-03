# DiscussionBridge for Discourse

This is the default-disabled v0.1 Alpha implementation for the forum-governed
DiscussionBridge control plane. It is a Ruby Discourse plugin, not a theme
component. It is not installed or deployed by this repository state.

## Current boundary

The plugin now implements authenticated create-or-resolve, canonical source
identity, forum-authoritative actor/category/tag policy, durable reservation and
mapping, controlled unlisted topic creation, and durable audit records. A retry
resolves the existing mapping rather than creating a second topic. The
operator may optionally configure explicit lane policies that select the
forum-owned category and tags for each adapter lane. Once lane policies exist,
missing and unknown lanes fail closed; adapter category/tag requests never
override forum policy. An empty lane-policy list preserves the global Alpha
category/tag behavior.

comments-only `fullInteractive` presentation is implemented locally behind a
default-disabled forum setting. For completed DiscussionBridge mappings, the
plugin adds its scoped class through Discourse Core's full-app redirect and
removes companion post 1 from embed layout only. The ordinary topic and its
first post remain unchanged. A native, administrator-only Health page reports
feature switches, connection readiness, operating identity, forum authority,
mapping state, and audit counts without exposing the connection credential.
The native Discourse Settings tab is the sole editable operator surface. Its
secret control remains write-only, and save-time validators reject malformed
origins, unavailable operating identities, nonexistent categories, and
nonexistent tags. Visible product copy uses `DiscussionBridge`; machine IDs,
route paths, setting names, and compatibility hooks retain their established
`discussion_bridge` or `discourse-discussion-bridge` forms.
A second administrator-only page provides a searchable, paginated, read-only
view of connection mappings and audit evidence. It exposes canonical source and
digest identity, state/outcome, topic, operating identity, reason, lane, and
timestamps, but omits credentials and raw requested/effective payloads. It has
no reconciliation or mutation controls.
A third administrator-only page provides a read-only reconciliation queue. It
detects missing/deleted topics, stale reservations, failed mappings, unknown
lanes, category/tag/actor/visibility drift, system authorship, and duplicate
source/topic claims if database invariants have been compromised. Every issue
has a deterministic severity, reason, and recommended operator action; the page
contains no delete, relist, retag, remap, or authorship control. Its first
bounded reconciliation action lets an administrator authorize one fresh
adapter retry for a failed mapping or a reservation stale for at least 15
minutes. Authorization is audited and may be revoked before use. The next
authenticated adapter request consumes it, replaces the old reservation token,
and must pass current forum policy before creating anything.

Safe defaults:

- plugin disabled;
- endpoint disabled;
- new-topic policy unlisted;
- Core zero-touch compatibility disabled;
- comments-only `fullInteractive` disabled;
- no operating identity configured;
- no trusted origins configured; and
- no topic or post mutation on plugin load;
- no Core fallback when the controlled endpoint rejects a request.

The complete contract is maintained in the Astro repository at
`docs/evidence/DISCUSSIONBRIDGE_PLUGIN_V0_1_CONTRACT_2026-08-02.md`.

## Development placement

Current local root:

`C:\CodeProjects\CodeWorksLabs\DiscussionBridge\plugins\discourse-discussion-bridge`

The intended standalone repository identity is
`DiscussionBridge/discourse-discussion-bridge`. Do not install this directory
under `theme-components`.

## Local verification

The controlled-creation and comments-only request boundaries are verified
against stock Discourse commit
`6b2f4579ba6802a7c556459e596c3150b67403aa` with Ruby 3.4.10. Both plugin
migrations pass in the local test databases, Discourse RuboCop reports zero
offenses across the reviewed Ruby scope, and the complete plugin RSpec coverage
passes 80 examples, including all four browser scenarios for compact native
zero-reply state, visible replies/actions, and unchanged ordinary long-topic
presentation, plus rejection of a caller-supplied reserved marker while the
operator option is disabled. The local development-server runtime also passes
empty, replied, ordinary-topic, operator-disable rollback, and reserved-marker
rejection checks after full client boot. The 2026-08-03 browser replay passes
4/4 after restoring the local Discourse Rollup frontend process.
Signed-in manual acceptance additionally confirmed native reply persistence on
the empty, replied, and ordinary-topic fixtures without changing ordinary topic
presentation.
Disposable host-frame acceptance confirmed natural empty/replied iframe sizing,
and the browser suite now proves that increasing omitted companion-post content
does not inflate the reported Discourse application height.
Forum-controlled local creation also passes under a dedicated non-system service
identity: the first request created one unlisted topic, retry resolved the same
mapping, an underprivileged identity now fails closed as `unlisted_denied`, and
the endpoint was disabled with its sandbox credential cleared after acceptance.
A focused five-example contract verifies the read-only Health endpoint, nested
administrator page routing, administrator authorization, explicit readiness
blockers, and secret containment. Discourse ESLint, Prettier, and Stylelint accept the native admin
route, navigation entry, Glimmer page, and scoped stylesheet.
A reviewed live nonproduction installation remains open. The settled progression
is local development, disposable `sandbox-forum.discussionbridge.dev`
integration testing, stable `dev-forum.discussionbridge.dev` preproduction
acceptance, and only then the production `forum.discussionbridge.dev` forum.
The three hosted forums must use separate databases, credentials, deployment
identities, and rollback boundaries.

This is development evidence, not installation or production acceptance.

## Install and test later

Before any installation, record the exact supported Discourse commit and run
the plugin through that checkout's standard plugin RSpec harness. An operator
installation will normally place or symlink the plugin under
`discourse/plugins/discourse-discussion-bridge`, run migrations, rebuild the
application, and leave the plugin and endpoint disabled until acceptance.

No live installation is authorized by this implementation state.

## Disable, rollback, and removal

1. Disable the endpoint.
2. Disable the plugin.
3. Verify ordinary topics and Core embeds remain unchanged.
4. Export or retain mapping/audit rows under an approved retention policy.
5. Reverse migrations only under a reviewed backup and rollback plan.
6. Remove the plugin directory and rebuild Discourse.

Never drop mapping or audit data merely to disable the plugin. Existing-topic
authorship, visibility, category, tag, or mapping changes require a separate
migration plan.

## License

GPL-2.0-or-later.
