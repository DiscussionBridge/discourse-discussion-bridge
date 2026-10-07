# The Bridge — DiscussionBridge for Discourse

## Recovery candidate — not a release or installation instruction

This isolated source starts from Alpha.30 (`9e64b4a83d5f`) and implements the
selected To-Discourse adoption/revision repair against the approved local
Adapter Protocol Alpha.22 (`827d943a7327`). The version metadata below still
identifies the retained baseline; these changed bytes are not the Alpha.30
release and must not be packaged or deployed under its tag.

Initial eligible Core-embed adoption does not edit the existing topic or first
post. An explicit later source revision uses native Discourse revision history;
exact source replays do not rewrite the post. Source clock strings are stored
without losing fractional precision. Unknown historical revision data remains
unknown and requires reconciliation before automatic updates.

Only `simple`, `full`, and `interactive` are accepted presentation values. The
canonical setting is `discussion_bridge_comments_only_interactive`; there is
no old-name fallback or automatic saved-setting transfer.

The catalog/destination-policy/work/lease/acknowledgement and restoration graph,
URL-migration proof and Operator action/audit groups remain pending.
Exact-revision source detail, byte-chunk and pinned inventory routes implement
source-side parts of that graph, not an operational delivery worker. New captures
retain author/category/tag descriptions and the source URL at capture time.
Older captures without those fields remain untouched and require reconciliation;
reads never invent or backfill that context. Source reads do not acknowledge
publication. Responses are private/no-store, scoped to an exact current
connection and public topic, and retain full source bytes without an aggregate
content ceiling. Destination limits remain separate.
Explicit publication also records append-only inventory observations atomically.
An initial snapshot fixes its observation cut under the connection lock; later
revisions cannot replace that cut. Each page scans at most its requested limit
(default25, maximum100), skips superseded/private observations with real cursor
progress, and rechecks current scope and native identity. A successful page
extends snapshot retention for30days; expiry does not delete publication history.
Inventory reads never manufacture earlier observations or acknowledge delivery.
Source withdrawal notices are append-only and tied to an already-observed
connection, resource, binding and exact retained source revision. Native
first-post/topic deletion, category visibility changes and connection scope
changes enqueue bounded jobs over those observed bindings. Each job rechecks
current source eligibility; it does not withdraw content that has become
eligible again before the job runs. Unmapped topics and disabled publisher
installations do not produce notices. These hooks record current withdrawal
conditions, not a complete history of transient changes.
Authenticated `/v1/source-revocations.json` and
`/v1/source-revocations/{resource_id}.json` return retained notice metadata even
after the source is private or outside its former origin/lane scope. They never
return the source body/title/URL, manufacture a notice or acknowledge delivery.
The index pins a finite connection-owned notice cut, defaults to25 items and
accepts at most100; signed cursors bind connection, cut and current policy.
Successful reads extend cursor-window activity for30days. Notices are retained
indefinitely in this implementation, including beyond the90-day minimum; no
purge or implicit-ACK shortcut is implemented. Native current-state producers
cover `source_deleted`, `source_unpublished` and `scope_removed`. Operator/policy
hold producers and delivery/ACK remain separate implementation work. These
source routes do not unpublish a destination.
Durable state and signed cursors are not, by themselves, process-restart, scale
or installation qualification; those gates remain open.
Explicit staff/admin From-Discourse publication now retains immutable whole
cooked native-source captures with actual first-post clocks and stable binding
identity. Reads use retained context and recheck current public visibility;
they do not capture or edit source posts. Explicit staff re-publication captures
a changed native revision, including a wiki edit or revert, without reusing an
older sequence. Native first-post edits (including wiki, title and taxonomy
changes), recovery, category visibility and connection scope events now enqueue
fixed-cut batches of at most100 already-observed bindings. Each refresh rechecks
current public source visibility, connection scope and retained native identity;
it updates the immutable source capture/observation without editing source posts,
binding identities or destination receipts. Returning after a retained native
withdrawal creates a higher source sequence, even for identical content and
native clocks. Duplicate callbacks/replays are idempotent. Operator/policy holds
are not cleared by source eligibility. Queued events observe the latest eligible
native state, not every transient intermediate revision. Disabled or unmapped
sources are inert. This implements source revision capture, not destination
update/restore delivery or staged ACK; those remain pending. Unknown historical context still fails
closed; no existing rows are backfilled or given invented synchronization dates.
New migration bindings have identity and presentation metadata, but never
inherit a destination publication receipt. The retained staff/admin paths are
not replaced. This is not a recovered whole plugin or an installation/release
candidate and has not been deployed.

The recovery branch is a source checkpoint, not a release. Local native
verification initially recorded 33 focused examples with zero failures and 164 broader
examples with four failures: three unfinished From-Discourse record reads and
one migrated-binding read without current metadata. No failing expectation was
skipped or weakened. GitHub Actions runs on every branch push; its exact-commit
result must be checked separately and cannot be inferred from those local tests.

The previous correction checkpoint adds Core's native plugin-enabled guards while
preserving the protocol's disabled response, updates migration-generated model
annotations, and fixes the four reported Ruby lint offenses. Local focused
regressions now run 34 examples with zero failures; Ruby lint inspects 74 files
with no offenses. Core's annotation generator leaves the model files unchanged,
but prints `constantize` warnings; its exit status alone is not annotation CI
qualification. Its actual GitHub run passed lint, annotations and 36 system
examples, but failed the four outbound/migration read expectations. The current
source repairs those paths and checks exact Alpha.22 response fields rather than
obsolete Alpha.20 fields. New regressions exercise retained source bytes/clocks,
privacy, unknown/tampered context, rollback, and bounded retries. Its own local
and exact-commit CI results must be checked separately; no prior result is
transferred. No new release, deployment or contract change is implied.

DiscussionBridge is a generic Discourse plugin for durable discussions shared
with publishing platforms. One forum can have any number of independent
Content Connections. Each connection represents one configured installation
of WordPress, Ghost, Statamic, Astro, publishing Discourse, or another future
adapter and manages many Bridge Records.

The plugin is default-disabled. Discourse remains authoritative for users,
topics, categories, tags, visibility, moderation, sessions, and replies.

The same downloadable plugin can receive connected-platform content, publish
explicitly selected Discourse topics to another DiscussionBridge forum, or do
both. Its role is configuration, not a separate receiver or publisher package.

## Product model

- **Content Connection** — one publishing-platform installation with its own
  credential, allowed origins, directions, lanes, adapter identity, and enabled
  state.
- **Bridge Record** — a stable plugin-issued resource identity linked to one
  Discourse topic.
- **Binding** — the current or historical external identity and canonical URL
  for one side of a Bridge Record.

Direction belongs to each Bridge Record, not to the connection:

- **To Discourse**: an authoritatively published external item creates or
  resolves one forum-governed discussion.
- **From Discourse**: an existing Discourse topic and first post are exposed to
  an authorized connection for external presentation. A platform that renders
  that first post may explicitly attach the same topic's Interactive
  replies; the attested comments-only frame omits the duplicate first post.

A migration prepares a replacement binding, preserves the resource and topic,
then makes the old binding historical when an administrator applies it.

## Native administration

Administrators use four pages under **Admin → Plugins → DiscussionBridge**:

- **Overview** — product health, connection and Bridge Record totals, both
  directions, readiness blockers, and a redacted support bundle.
- **Connections** — create, enable or disable independent connections and
  rotate a secret. The selected connection has a **General** tab and an
  **Authors** tab. A new secret is shown once and is never returned by later
  reads.
- **Bridge Records** — search and filter records, inspect bindings, create a
  From Discourse record, and perform a controlled migration.
- **Reconciliation** — inspect operational inconsistencies and export a
  redacted report.

The native Discourse Settings tab remains the editor for forum-wide policy.

## Adapter API

All adapter requests use HTTPS and JSON. Authentication is connection-scoped:

```text
X-DiscussionBridge-Connection: dbc_...
X-DiscussionBridge-Secret: ...
```

### Create or resolve a To Discourse record

```http
POST /discussion-bridge/v1/bridge-records/resolve.json
Content-Type: application/json
```

```json
{
  "bridge_record": {
    "direction": "to_discourse",
    "external_id": "post-482",
    "canonical_url": "https://publisher.example/articles/community-guide/",
    "title": "Community guide discussion",
    "content_html": "<h2>Community guide</h2><p>The published article body.</p>",
    "published": true,
    "visibility": "unlisted",
    "lane": "articles",
    "adapter_id": "publisher-adapter",
    "correlation_id": "delivery-1"
  }
}
```

Only exact boolean `published: true` is accepted. An adapter may also report a
bounded `source_authors` array and one `primary_source_author_id`. Every source
author has a stable platform identity, display name, and optional profile URL
on the connection's allowed origin. `content_html` is a required,
nonblank published-content snapshot bounded to 48 KiB inside the 64 KiB request
envelope. Discourse's ordinary post pipeline cooks and sanitizes it, and the
plugin adds canonical source attribution after the content. The connection
must authorize the direction, canonical origin, and lane. Forum policy selects
the visible author, category, tags, and visibility.

Each Content Connection chooses one publication-authorship mode:

- **Fixed Discourse author** uses the connection author, or the forum default
  when no connection override is present.
- **Mapped source author** maps the reported primary platform author to an
  active Discourse user. An unmapped primary author either falls back to the
  fixed author or holds publication before topic creation, according to that
  connection's policy.

The Authors tab shows identities actually observed from that connection and
lets an administrator map each one to an existing Discourse user. One primary
source author controls the topic owner; every reported source author is
credited in the companion post. Mapping changes apply to future topics and do
not silently reassign existing topics. The privileged operating identity
remains separate from a non-privileged visible author. A retry with the same external
identity and URL returns the same resource and topic without rewriting its
first-published snapshot; conflicting identity claims fail closed.

The General tab also offers **Generate topic table of contents** per Content
Connection. When enabled, a newly created To Discourse topic with at least two
source headings receives the official DiscoTOC marker. The forum must have the
DiscoTOC theme component installed; this setting does not install it. Platform
page navigation remains independent, and existing topics are not silently
rewritten when the setting changes.

An adapter may include `existing_topic_id` only while adopting a standalone
Discourse Core embed. The plugin creates a Bridge Record around that topic
without creating a replacement only when Core already attests the exact
canonical source URL, the topic is an available unlisted embed, and it has no
prior DiscussionBridge mapping. This is the automatic upgrade path from a
standard Core `full` embed. It is not authority to claim a manually selected
topic; those remain standalone until a forum operator explicitly adopts them.

### Read records visible to a connection

```http
GET /discussion-bridge/v1/bridge-records.json
GET /discussion-bridge/v1/bridge-records/:resource_id.json
```

For a From Discourse record, the response includes the first post's cooked HTML
and a `source` object containing the exact forum origin, topic/post identity,
post version, stable revision token, update timestamp, and visible author
identity. Adapters use that revision to create or update native platform
content idempotently; they must not infer change from mutable titles or URLs.
The response never includes another connection's record.

## Forum-wide settings

- `discussion_bridge_enabled`
- `discussion_bridge_endpoint_enabled`
- `discussion_bridge_service_username`
- `discussion_bridge_default_author_username`
- `discussion_bridge_effective_category_id`
- `discussion_bridge_effective_tags`
- `discussion_bridge_lane_policies`
- `discussion_bridge_default_visibility`
- `discussion_bridge_comments_only_interactive`

The endpoint and plugin switches are independently default-disabled. The
operating identity and forum-default author must be active, non-system Discourse
users. During upgrade, a blank default-author setting temporarily falls back to
the operating identity. A Content
Connection may select another active user without granting that author the
operating identity's privileges. Configured category and tags must already
exist. Optional lane policy is forum-owned and fails
closed for missing or unknown lanes once configured.

## Publish Discourse content to a connected platform

The native Publishing page creates a local From Discourse Bridge Record for an
existing topic and a selected Content Connection. The operator supplies the
platform's stable content identity and exact presentation URL. Exact retries
resolve the same record. One local topic may be published independently through
more than one platform connection. The authorized platform adapter retrieves
the record from this forum; no second receiving forum or outbound forum secret
is part of ordinary publishing.

Publishing authority is explicit per binding. **Authorize native
materialization** permits the selected adapter to create or update a genuine
platform record at that URL. When it is off, the record is presentation-only
and may be rendered inside an existing platform page; adapters must not infer
permission to create content from retrieval access alone.

## Presentation boundary

DiscussionBridge can qualify a healthy mapped topic for Discourse Core's
full-app embed. Core owns the iframe application, dynamic height,
authentication, composer, reply, quote, edit, Like, moderation, and session
behavior. The plugin only attests the exact Bridge Record/topic route and omits
companion post 1 from the mapped embed layout. The ordinary topic remains
unchanged.

No external publishing-platform adapter is implemented inside this repository.
An adapter translates its platform lifecycle into the generic connection API and
renders or links the returned discussion using platform-native code and
Discourse Core presentation.

## Install

Pin the plugin in the Discourse container configuration and rebuild the one
intended container:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/DiscussionBridge/discourse-discussion-bridge.git
          - cd discourse-discussion-bridge && git checkout <immutable-commit>
```

```bash
cd /var/discourse
./launcher rebuild app
```

Before installing, preserve the protected configuration and a whole-server or
database/uploads recovery point. A launcher rebuild reuses persistent Discourse
data and is not a clean installation.

After rebuild:

1. verify the installed plugin commit and pending migrations;
2. verify PostgreSQL, Redis, application processes, and HTTPS;
3. enable and configure forum policy;
4. create each Content Connection in native administration;
5. copy each one-time secret directly into its adapter's server-side secret
   store;
6. exercise both permitted directions and reconciliation before relying on the
   installation.

## Development verification

The plugin specs run inside a compatible Discourse checkout:

```bash
LOAD_PLUGINS=1 RAILS_ENV=test bundle exec rspec \
  plugins/discourse-discussion-bridge/spec
```

Generated plugin JavaScript must be rebuilt from current source before browser
system specs. Historical Alpha manifests and one-consumer acceptance records
are intentionally not part of this replacement product.

## License

See [LICENSE](LICENSE).
