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

This is qualification evidence, not public-release or production acceptance.

## Install and acceptance

Before any installation, record the exact supported Discourse commit and run
the plugin through that checkout's standard plugin RSpec harness. The release
record must provide `<RELEASE_TAG>` and its exact 40-character `<RELEASE_SHA>`.
The examples below assume an official Docker install rooted at
`/var/discourse`; stop and confirm the real root, container names, and current
configuration before copying them. Do not substitute a moving branch.

### Human installation is a release gate

The automated and stable-preproduction installations qualify the software, but
they do not prove that a real forum administrator can install the released
plugin from its public instructions. Every Alpha release that claims
plugin-backed `fullInteractive` support therefore requires human-admin
installations of the exact published plugin candidate in both supported
deployment topologies: the standard single-container `app` proof on
`sandbox-forum.discussionbridge.dev` and the official split `data` + `web_only`
proof on `dev-forum.discussionbridge.dev`. The same person may perform both, but
each host/topology must begin from its recorded clean rollback point and produce
its own acceptance record. `forum.repealobbba.org` is not a substitute or third
current release-gate install; any later independent real-world proof there
requires separate OBBBA authorization and recovery acceptance.

The release record must name the immutable plugin tag and commit SHA. The human
administrator must use that public GitHub identity, not a local checkout or
moving branch.

#### 1. Preflight and recovery identity

From a private administrator shell, confirm the install root and topology:

```bash
cd /var/discourse
pwd
./launcher list
test -f containers/app.yml && echo SINGLE_CONTAINER_CANDIDATE
test -f containers/web_only.yml && echo TWO_CONTAINER_CANDIDATE
```

Stop if the root is not the intended forum, the topology is ambiguous, an
unexpected DiscussionBridge entry or installation already exists, the forum is
unhealthy, capacity is inadequate, or the release tag does not resolve to the
recorded SHA. Confirm a readable Discourse application backup and the separate
host/provider rollback identity before editing. Creating and verifying the
application backup through `/admin/backups` is preferred because it records the
forum-owned artifact without printing secrets. Record its name, completion,
time, and protected location; never paste its contents into the release record.

Create a protected copy of only the topology's application configuration:

```bash
cd /var/discourse
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
# Choose exactly one after confirming the topology:
cp -a containers/app.yml "containers/app.yml.pre-discussionbridge-$stamp"
# OR, for the split topology:
cp -a containers/web_only.yml "containers/web_only.yml.pre-discussionbridge-$stamp"
```

Record the chosen backup filename. Do not copy or edit `data.yml` for the split
topology.

#### 2A. Standard single-container install

Edit `containers/app.yml` and add these commands to its existing
`hooks: after_code: - exec: cmd:` list. Preserve every existing hook and YAML
indentation:

```yaml
          - git clone https://github.com/DiscussionBridge/discourse-discussion-bridge.git
          - git -C discourse-discussion-bridge checkout --detach <RELEASE_SHA>
```

The hook's `cd` must be `$home/plugins`, as in the official Discourse plugin
installation pattern. Confirm the resulting YAML diff contains only the two
DiscussionBridge commands, then rebuild only `app`:

```bash
cd /var/discourse
./launcher rebuild app
```

#### 2B. Official split `data` + `web_only` install

Edit only `containers/web_only.yml` and add the same two commands to its
existing `hooks: after_code: - exec: cmd:` list:

```yaml
          - git clone https://github.com/DiscussionBridge/discourse-discussion-bridge.git
          - git -C discourse-discussion-bridge checkout --detach <RELEASE_SHA>
```

The hook's `cd` must be `$home/plugins`. Confirm the diff, then rebuild only
`web_only`:

```bash
cd /var/discourse
./launcher rebuild web_only
```

Do not add the plugin to `data.yml`, edit `data.yml`, or rebuild `data`.

#### 3. Postflight and acceptance

Because the application root inside a container can differ, discover the
installed plugin path instead of assuming `/var/www/discourse`. Choose the same
application container rebuilt above:

```bash
cd /var/discourse
./launcher enter app
# OR: ./launcher enter web_only
plugin_git=$(find / -type d -path '*/plugins/discourse-discussion-bridge/.git' -print -quit 2>/dev/null)
test -n "$plugin_git" || { echo PLUGIN_PATH_NOT_FOUND; exit 1; }
plugin_root=${plugin_git%/.git}
git -C "$plugin_root" rev-parse --verify HEAD
git -C "$plugin_root" status --short
exit
```

The reported HEAD must equal `<RELEASE_SHA>` and tracked status must be empty.
In Discourse admin, confirm there is no failed or pending migration; the plugin
is present; `discussion_bridge_enabled`,
`discussion_bridge_endpoint_enabled`,
`discussion_bridge_core_zero_touch_compatibility`, and
`discussion_bridge_comments_only_full_interactive` are all off; no connection
ID/secret, trusted origin, service username, category, tag, or lane policy was
silently populated; and ordinary topics, admin access, HTTPS, PostgreSQL, and
Redis remain healthy. Only then apply the separately reviewed connection
settings, enable the plugin, and exercise the approved create/resolve and
presentation checks. Disable the endpoint at rest unless a bounded creation
request is actively running.

The human acceptance record must confirm:

1. backup/rollback identity before the change;
2. successful install and migrations from the public release instructions;
3. the installed commit equals the release record;
4. all DiscussionBridge settings remain at safe defaults/off after rebuild;
5. ordinary forum topics, admin access, HTTPS, database, and Redis remain
   healthy;
6. the documented enable/configure flow works for the intended connection;
7. disable and rollback/removal instructions are understandable and effective.

Alpha release acceptance does not close until that human result is received
and dispositioned. A failure produces a corrected candidate under a new tag;
never rewrite an existing release tag or silently replace its source.

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

First disable `discussion_bridge_endpoint_enabled`, then
`discussion_bridge_enabled`, and verify ordinary topics and Core embeds remain
unchanged. Export or retain mapping/audit rows under the approved retention
policy; never drop them merely to disable the plugin.

Restore the exact protected configuration copy created during preflight. Use
only the command matching the confirmed topology and substitute the recorded
timestamp:

```bash
cd /var/discourse
# Single-container only:
cp -a "containers/app.yml.pre-discussionbridge-<TIMESTAMP>" containers/app.yml
./launcher rebuild app

# OR split topology only:
cp -a "containers/web_only.yml.pre-discussionbridge-<TIMESTAMP>" containers/web_only.yml
./launcher rebuild web_only
```

For the split topology, never edit or rebuild `data` during plugin removal.
After the rebuild, confirm the plugin path is absent, the forum/admin/HTTPS/
PostgreSQL/Redis baseline is healthy, ordinary topics and Core embeds are
unchanged, and retained mapping/audit data follows the approved policy. If the
forum or migrations fail, stop normal work and invoke the predeclared
application-backup or provider-snapshot rollback; do not improvise destructive
migration reversal. Reverse migrations only under that separately reviewed
backup and rollback plan.

Existing-topic authorship, visibility, category, tag, or mapping changes
require a separate migration plan.

## License

GPL-2.0-or-later.
