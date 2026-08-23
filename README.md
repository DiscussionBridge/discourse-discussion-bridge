# DiscussionBridge for Discourse

This is the default-disabled v0.1 Alpha implementation for the forum-governed
DiscussionBridge control plane. It is a Ruby Discourse plugin, not a theme
component. Repository source state and installed forum state are accepted and
tracked separately.

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

`C:\CodeProjects\Products\DiscussionBridge\plugins\discourse-discussion-bridge`

The intended standalone repository identity is
`DiscussionBridge/discourse-discussion-bridge`. Do not install this directory
under `theme-components`.

## Local verification

The current candidate is verified against the exact stable-preproduction
Discourse commit `36698aae084678151dffa875d49c8d59216d2733` (public version
`2026.8.0-latest.1`). Both plugin migrations pass; Discourse RuboCop accepts all
47 Ruby files; i18n, ESLint, and Prettier pass; the complete plugin suite passes
78/78 server/plugin examples and 4/4 browser/system examples. The three admin
route templates use current `.gjs` modules; this removes the
`discourse.hbs-extension` notice found during real-user dev acceptance. The
plugin has no QUnit test files. Two aggregate QUnit launcher attempts failed in
the 2 GB isolated host before any DiscussionBridge assertion—first on browser
connection timeout, then on a parallel plugin-build worker death—so they are
recorded as harness-capacity evidence, not a product test failure. Browser
behavior is covered by the passing four system examples and live dev checks.
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
A reviewed live nonproduction installation is present on stable
`dev-forum.discussionbridge.dev` at plugin SHA
`50c4a92359f672a00b2242e99819a70813ebea19`. Installation, migrations, reviewed
settings, create-then-resolve, comments-only presentation, ordinary-topic
isolation, Health/Operations/Reconciliation, and retry-authorization proofs
passed on 2026-08-22. The `.gjs` compatibility correction described above is
installed and the prior admin deprecation notice is absent after browser reload.
Clean snapshot restore/reinstall, direct mobile acceptance, and a separately
deployed dev-targeted Starlight page with an authenticated non-admin reply also
pass. A fresh post-restore Discourse SMTP message to Postmark's nondelivering
blackhole recipient passed without exposing credentials. Disable/re-enable,
record-only upgrade, and rollback to the qualified installed SHA also pass with
forum data and the real reply preserved. Production promotion remains separate.
The settled progression is local development,
`sandbox-forum.discussionbridge.dev` integration testing, stable preproduction
acceptance, and only then the production `forum.discussionbridge.dev` forum.
The three hosted forums must use separate databases, credentials, deployment
identities, and rollback boundaries.

This is development evidence, not installation or production acceptance.

## Install and acceptance

Before any installation, record the exact supported Discourse commit and run
the plugin through that checkout's standard plugin RSpec harness. An operator
installation will normally place or symlink the plugin under
`discourse/plugins/discourse-discussion-bridge`, run migrations, rebuild the
application, and leave the plugin and endpoint disabled until acceptance.

### Protect rebuild output

Discourse's standard `launcher rebuild` output can echo the final Docker command
with environment values, including forum-wide SMTP and database credentials.
That is upstream launcher behavior, not a DiscussionBridge setting, but it is
part of the real installation boundary.

- Run launcher commands only in a private administrator terminal.
- Never stream raw launcher output into CI logs, Codex/chat, issues, support
  tickets, or shared transcripts.
- If output must be retained, capture it in a root-only file with restrictive
  permissions, sanitize every environment assignment before sharing, and then
  dispose of the protected raw copy under the operator's retention policy.
- Treat any unredacted launcher transcript as credential-bearing even when the
  rebuild succeeds. Do not assume that ordinary installer output is safe merely
  because no DiscussionBridge secret was passed on the command line.
- Verify the installed plugin SHA, migrations, settings, and service health with
  separate sanitized commands after rebuild instead of sharing the raw rebuild
  transcript.

The accepted dev-forum installation does not authorize production installation
or promotion. Production remains a separate reviewed release gate.

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
