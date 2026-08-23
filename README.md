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
first post remain unchanged. Discourse Core supplies the native in-frame
composer, reply, quote, edit, Like, and sign-in behavior; DiscussionBridge does
not reimplement those security-sensitive actions. If the plugin capability is
enabled for a completed mapping while Discourse's `embed_full_app` setting is
off, the request fails closed instead of silently serving the legacy
Start/Continue Discussion handoff embed. A native, administrator-only Health page reports
feature switches, connection readiness, operating identity, forum authority,
mapping state, and audit counts without exposing the connection credential.
The native Discourse Settings tab is the sole editable operator surface. Its
secret control remains write-only, and save-time validators reject malformed
origins, unavailable operating identities, nonexistent categories, and
nonexistent tags. Visible product copy uses `DiscussionBridge`; machine IDs,
route paths, setting names, and compatibility hooks retain their established
`discussion_bridge` or `discourse-discussion-bridge` forms.
A corrected Alpha.5 candidate also keeps the mapped comments route across
in-frame authentication transitions and gives Core's compact composer submit
control an explicit visible **Post reply** label for creation/reply and **Save
edit** while editing an allowed post. For a completed mapping, the server issues
an expiring signed attestation bound to the exact mapping, database-precision
mapping version, topic, and accepted presentation class. The browser arms a
two-minute, one-use return only when the user activates Core's actual logout
control inside that mapped iframe. The state
travels in that iframe's own browsing context and is consumed and cleared on the
next initialized iframe page. Restoration occurs only at Core's reviewed logout
destinations, where the server revalidates it before restoring the exact mapped
topic; every other destination fails closed. It does not store a general topic
URL, react to ordinary navigation, share state across sibling iframes, or
redirect a popup or top-level forum window. Malformed clocks, future issue times,
and expiry windows longer than two minutes fail closed. Restoration also rechecks
both Core full-app and full-app sign-in-flow settings. Core's popup sign-in/sign-up flow
continues to reload the already mapped iframe directly. Discourse Core owns authentication, account
creation, sessions, authorization, moderation, editing, and post submission.
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

Initial Alpha.5 commit `7d6945a453048c92e64d235a8ed1652e6a8efc16`
passed automated qualification, but independent Code review rejected its
origin-wide client route storage. That commit is evidence ancestry, not a
release candidate. Corrected production-code commit
`8e311968990a61f0fb3d07ae7757647d0783c71a` binds attestation to the exact
database-precision mapping version, rechecks the complete Core readiness
contract at restore, and enforces a fail-closed two-minute, one-use,
per-browsing-context logout return. That exact head passed Discourse's official reusable
plugin workflow against stable-preproduction Discourse commit
`36698aae084678151dffa875d49c8d59216d2733` (public version
`2026.8.0-latest.1`) in
[workflow run 32656418990](https://github.com/DiscussionBridge/discourse-discussion-bridge/actions/runs/32656418990).
The corrected suite reports 83 server/plugin and 11 browser/system examples with
zero failures, plus passing lint and annotations. It covers editing, actual
logout restoration, two mapped sibling iframes, an unrelated Core iframe, stale
state, future/overlong/malformed clock state, deliberate non-auth navigation,
top-level non-redirection, post-issuance readiness-setting changes, and forged,
mapping-mismatched, or same-second subsecond-stale attestations. It continues to prove
the completed-mapping 503 guard, readiness
blockers, comments-only isolation, native empty-state and existing-post replies,
Like persistence, and Quote submission in Core embed mode. The plugin has no
QUnit files. The actual Astro-hosted iframe and signed-out embed sign-in flow
remain mandatory human release gates below; direct Core system tests do not
substitute for those two browser boundaries.

Earlier Alpha.2-era qualification additionally proved natural empty/replied
iframe sizing and that increasing omitted companion-post content does not inflate
the reported Discourse application height. That evidence remains valid for the
unchanged presentation behavior but does not qualify Alpha.2's rejected
`fullInteractive` promise.
Forum-controlled local creation also passes under a dedicated non-system service
identity: the first request created one unlisted topic, retry resolved the same
mapping, an underprivileged identity now fails closed as `unlisted_denied`, and
the endpoint was disabled with its sandbox credential cleared after acceptance.
A focused five-example contract verifies the read-only Health endpoint, nested
administrator page routing, administrator authorization, explicit readiness
blockers, and secret containment. Discourse ESLint, Prettier, and Stylelint accept the native admin
route, navigation entry, Glimmer page, and scoped stylesheet.
A reviewed predecessor nonproduction installation remains present on stable
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
record-only upgrade, and rollback to that qualified predecessor SHA also pass
with forum data and the real reply preserved. The Alpha.2 human sandbox test was
rolled back to its recorded prior SHA
`05bbf481c1eeca2e26e82cfeb8e5d31963f89e92`. Neither installed predecessor is
Alpha.3 acceptance evidence. Production promotion remains separate.
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
they do not prove that a real forum administrator can install the published
prerelease candidate from its public instructions. Every Alpha prerelease
candidate that claims plugin-backed `fullInteractive` support therefore requires
human-admin installations of the exact published plugin candidate in both
supported container arrangements: the standard single-container `app` proof on
`sandbox-forum.discussionbridge.dev` and the official split `data` + `web_only`
proof on `dev-forum.discussionbridge.dev`. The same person may perform both, but
each forum/container arrangement must begin from its recorded clean rollback
point and produce its own acceptance record. `forum.repealobbba.org` is not a
substitute or third current release-gate install; any later independent real-world proof there
requires separate OBBBA authorization and recovery acceptance.

The release record must name the immutable plugin tag and commit SHA. The human
administrator must use that public GitHub identity, not a local checkout or
moving branch.

Release history: public prerelease `v0.1.0-alpha.0` is immutable and remains as
dated evidence. Its first human preflight exposed an unsupported launcher
inspection command before any configuration edit, rebuild, or forum mutation.
Corrected `v0.1.0-alpha.1` then identified an expected historical pinned plugin
hook but did not provide a public pinned-upgrade path; that pass also stopped
before configuration edit, rebuild, or forum mutation. Both earlier tags remain
immutable dated evidence. Corrected `v0.1.0-alpha.2` completed public pinned
installation and rollback, but Phil's real-user pass proved its behavior labeled
`fullInteractive` renders comments and hands interaction off to Discourse rather
than completing native actions inside the Astro-page iframe. Code and historical
doctrine review confirm that is a product-contract blocker. Alpha.2 is rejected
for installation. The corrected Alpha.3 source fails closed when the required
Core full-app setting is absent and adds native action-completion coverage; it
passed exact qualification and independent Code/Manual review and was published
as immutable prerelease candidate `v0.1.0-alpha.3` at commit
`075388cdc6dbfe1112ee0a82dc0cec497e2c913b`. Its release page is the publication
record. The tag's own immutable README necessarily retains the prepublication
candidate-state sentence that existed before the tag and release were created;
that dated sentence is superseded by the release record and this current README.
Alpha.3's human preflight then exposed that the procedure required the operator
to record the protected rollback-configuration filename but never displayed its
expanded value. The test stopped before configuration edit, rebuild, plugin
installation, or forum mutation. Alpha.3 is rejected for installation and
remains immutable evidence. Corrected Alpha.4 displays the exact chosen filename
as part of the protected-copy step, but human acceptance found an ambiguous
icon-only submit action, comments-route loss across authentication transitions,
and a missing new-user sign-up/return gate. Alpha.4 is rejected for installation
and remains immutable evidence. Alpha.5 labels the submit action, adds
server-attested one-use iframe logout recovery, and adds explicit
sign-up/activation/approval/return acceptance. It was published as immutable
prerelease candidate `v0.1.0-alpha.5` at exact commit
`94f90811e5178752b1c54c16c15207dfe78e3bb6`; its
[release page](https://github.com/DiscussionBridge/discourse-discussion-bridge/releases/tag/v0.1.0-alpha.5)
is the publication authority. The tag's README retains its truthful
prepublication sentence as dated evidence. All six published tags remain
immutable and must not be rewritten, retagged, or silently replaced.

#### 1. Preflight and recovery identity

From a private administrator shell, confirm the Discourse folder and container
arrangement. A standard setup has one `app` container; a split setup has separate
`data` and `web_only` containers:

```bash
cd /var/discourse
pwd
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
test -f containers/app.yml && echo SINGLE_CONTAINER_CANDIDATE
test -f containers/web_only.yml && echo TWO_CONTAINER_CANDIDATE
```

Stop if this is not the intended forum, the container arrangement is unclear, an
unrecognized DiscussionBridge entry or installation exists, the forum is
unhealthy, capacity is inadequate, or the release tag does not resolve to the
recorded SHA. If the host has an expected, recorded, pinned DiscussionBridge
hook, use the pinned-upgrade procedure below rather than adding a second clone
entry. Confirm the accepted host-specific recovery boundary before
editing: a readable Discourse application backup, a completed provider snapshot,
or both, according to the forum's recorded role and recovery decision. A
disposable sandbox may use a separately accepted provider snapshot without an
application backup; durable preproduction and production forums must follow
their stricter recorded recovery policy. When an application backup is required,
creating and verifying it through `/admin/backups` is preferred because it
records the forum-owned artifact without printing secrets. Record the accepted
artifact or snapshot identity, completion, time, and protected location; never
paste protected contents into the release record.

Create a protected copy of only the confirmed container arrangement's
application configuration. Run exactly one of the following blocks.

For the standard single-container `app` arrangement:

```bash
cd /var/discourse
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
source_config="containers/app.yml"
rollback_config="containers/app.yml.pre-discussionbridge-$stamp"
if [ ! -f "$source_config" ] || [ ! -r "$source_config" ]; then
  printf 'SOURCE_CONFIG_NOT_READABLE=%s\n' "$source_config" >&2
  false
elif [ -e "$rollback_config" ]; then
  printf 'ROLLBACK_CONFIG_EXISTS=%s\n' "$rollback_config" >&2
  false
elif cp -a -- "$source_config" "$rollback_config" &&
  [ -f "$rollback_config" ] &&
  [ -r "$rollback_config" ] &&
  cmp -s -- "$source_config" "$rollback_config"; then
  printf 'ROLLBACK_CONFIG=%s\n' "$rollback_config"
else
  printf 'ROLLBACK_CONFIG_COPY_FAILED=%s\n' "$rollback_config" >&2
  false
fi
```

For the split `data` + `web_only` arrangement:

```bash
cd /var/discourse
umask 077
stamp=$(date -u +%Y%m%dT%H%M%SZ)
source_config="containers/web_only.yml"
rollback_config="containers/web_only.yml.pre-discussionbridge-$stamp"
if [ ! -f "$source_config" ] || [ ! -r "$source_config" ]; then
  printf 'SOURCE_CONFIG_NOT_READABLE=%s\n' "$source_config" >&2
  false
elif [ -e "$rollback_config" ]; then
  printf 'ROLLBACK_CONFIG_EXISTS=%s\n' "$rollback_config" >&2
  false
elif cp -a -- "$source_config" "$rollback_config" &&
  [ -f "$rollback_config" ] &&
  [ -r "$rollback_config" ] &&
  cmp -s -- "$source_config" "$rollback_config"; then
  printf 'ROLLBACK_CONFIG=%s\n' "$rollback_config"
else
  printf 'ROLLBACK_CONFIG_COPY_FAILED=%s\n' "$rollback_config" >&2
  false
fi
```

Proceed only when the chosen block prints `ROLLBACK_CONFIG`. Record that exact
value. Any `SOURCE_CONFIG_NOT_READABLE`, `ROLLBACK_CONFIG_EXISTS`, or
`ROLLBACK_CONFIG_COPY_FAILED` marker is a stop condition. Do not copy or edit
`data.yml` for the split container arrangement.

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

#### 2C. Existing pinned installation upgrade

Use this path only when preflight identifies an expected prior installation and
the confirmed container-arrangement configuration contains exactly one clone of
the official
`DiscussionBridge/discourse-discussion-bridge` repository with exactly one
recorded immutable commit pin. Stop if the repository is nonstandard, the prior
identity is unknown, the hook is duplicated, or it follows a branch or other
moving reference.

Record the prior installed/configured SHA and the protected configuration copy
created during preflight. In only the confirmed container-arrangement file,
replace the old
immutable checkout SHA with `<RELEASE_SHA>` while preserving the existing hook
form, URL, surrounding hooks, and YAML indentation. Do not add a second clone
command and do not update the running container with `git pull`.

Confirm the configuration diff changes only that one pinned SHA. Then rebuild
only the application container matching the confirmed container arrangement:

```bash
cd /var/discourse
# Standard single-container only:
./launcher rebuild app

# OR official split container arrangement only:
./launcher rebuild web_only
```

For the split container arrangement, never edit `data.yml` or rebuild `data`.
Continue with the
same postflight, safe-default, forum-health, enable/configure, and rollback
checks below. Rollback restores the protected pre-upgrade configuration copy and
rebuilds only the same application container, returning the hook to the recorded
prior immutable SHA.

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
plugin_sha=$(git -c safe.directory="$plugin_root" -C "$plugin_root" rev-parse --verify HEAD) || {
  echo PLUGIN_SHA_READ_FAILED
  exit 1
}
plugin_status=$(git -c safe.directory="$plugin_root" -C "$plugin_root" status --porcelain) || {
  echo PLUGIN_STATUS_READ_FAILED
  exit 1
}
printf 'PLUGIN_SHA=%s\n' "$plugin_sha"
test -z "$plugin_status" && echo PLUGIN_TRACKED_CLEAN=true || {
  echo PLUGIN_TRACKED_CLEAN=false
  exit 1
}
exit
```

The reported HEAD must equal `<RELEASE_SHA>`. The command-scoped
`safe.directory` allowance handles the container's expected ownership boundary
without changing global Git configuration, and any Git read failure stops rather
than being misreported as a clean checkout.

In Discourse admin, confirm there is no failed or pending migration and the
plugin is present. Apply the settings postcondition matching the preflight state:

- **Fresh install:** `discussion_bridge_enabled`,
  `discussion_bridge_endpoint_enabled`,
  `discussion_bridge_core_zero_touch_compatibility`, and
  `discussion_bridge_comments_only_full_interactive` are all off; no connection
  ID/secret, trusted origin, service username, category, tag, or lane policy was
  silently populated.
- **Pinned upgrade:** the previously recorded, approved sanitized settings are
  preserved exactly; no setting is reset, enabled, disabled, or populated merely
  by rebuilding. An upgrade must not be expected to reset existing settings to
  fresh-install defaults.

Before claiming or exercising `fullInteractive`, use Discourse admin to search
the Embedding settings and confirm both of these Core settings:

- **Embed full app** is enabled. Without it, Discourse serves its legacy
  Start/Continue Discussion embed rather than the interactive application.
- **Embed full app signin flow** is enabled for the accepted same-site Alpha
  hosts. For an unrelated host and forum domain, stop and review Discourse's
  cookie requirements before enabling this setting.

Then enable `discussion_bridge_comments_only_full_interactive` only under the
reviewed host policy. The DiscussionBridge Health page must report **In-page
interaction readiness: Ready** with no `embed_full_app_disabled` or
`embed_full_app_signin_flow_disabled` blocker. A legacy Start/Continue
Discussion button is a failed preflight, not `fullInteractive` acceptance.

Confirm ordinary topics, admin access, HTTPS, PostgreSQL, and Redis remain
healthy. Only then apply any separately reviewed settings change and exercise
the approved create/resolve and presentation checks. Disable the endpoint at
rest unless a bounded creation request is actively running. At rest, the plugin
health view can label `endpoint_disabled` as **Needs attention**. In this
specific state that label confirms the creation endpoint is safely closed; it
is not an install or migration failure.

The human acceptance record must confirm:

1. backup/rollback identity before the change;
2. successful install and migrations from the public release instructions;
3. the installed commit equals the release record;
4. fresh-install settings remain at safe defaults/off, or a pinned upgrade
   preserves the recorded approved settings exactly;
5. ordinary forum topics, admin access, HTTPS, database, and Redis remain
   healthy;
6. the documented enable/configure flow works for the intended connection;
7. an authenticated human completes Reply, Like, and Quote inside the Astro-page
   iframe without top-level navigation, and the composer submit action has a
   clear visible **Post reply** label;
8. the same human edits an allowed post inside the Astro-page iframe, sees the
   clear visible **Save edit** label, saves successfully without top-level or
   popup navigation, and remains subject to Discourse Core's ordinary editing
   authorization and moderation;
9. an existing user signs out, the mapped Astro discussion handles the lost
   session honestly with signed-out state visible and no popup or top-level forum
   restoration, and a subsequent reviewed sign-in returns to the validated
   originating Astro discussion without an orphan forum-homepage state or manual
   refresh;
10. a brand-new ordinary user initiates sign-up from the Astro-hosted discussion,
   completes the forum's email activation and approval policy where required,
   returns through the validated original Astro context, and participates under
   normal hold/review moderation without staff elevation or unapproved-body
   disclosure; and
11. disable and rollback/removal instructions are understandable and effective.

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
only the command matching the confirmed container arrangement and substitute the
recorded
timestamp:

```bash
cd /var/discourse
# Single-container only:
cp -a "containers/app.yml.pre-discussionbridge-<TIMESTAMP>" containers/app.yml
./launcher rebuild app

# OR split container arrangement only:
cp -a "containers/web_only.yml.pre-discussionbridge-<TIMESTAMP>" containers/web_only.yml
./launcher rebuild web_only
```

For the split container arrangement, never edit or rebuild `data` during rollback or
removal.
Then apply only the postcondition matching the preflight state:

- **Fresh-install removal:** the restored configuration had no DiscussionBridge
  hook. Enter the rebuilt `app` or `web_only` container, repeat the postflight
  path discovery, and confirm no `discourse-discussion-bridge/.git` path exists.
- **Pinned-upgrade rollback:** the restored configuration contains the recorded
  prior official hook. Enter the rebuilt `app` or `web_only` container, repeat
  the postflight path discovery, and confirm the plugin is present, its HEAD is
  exactly `<PRIOR_SHA>`, and tracked status is clean. Absence is a rollback
  failure in this case; do not remove the legitimate prior installation.

For either outcome, confirm the forum/admin/HTTPS/PostgreSQL/Redis baseline is
healthy, ordinary topics and Core embeds are unchanged, and retained
mapping/audit data follows the approved policy. If the forum or migrations fail,
stop normal work and invoke the predeclared application-backup or
provider-snapshot rollback; do not improvise destructive migration reversal.
Reverse migrations only under that separately reviewed backup and rollback
plan.

Existing-topic authorship, visibility, category, tag, or mapping changes
require a separate migration plan.

## License

GPL-2.0-or-later.
