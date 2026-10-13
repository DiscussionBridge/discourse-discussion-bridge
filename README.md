# The Bridge — DiscussionBridge for Discourse

Local build candidate: family `0.3.0-alpha.1`, native component
`0.3.0.alpha.1`, bridge compatibility `0.3`. The additive candidate contract is
[`core-publication-extension.json`](../adapter-contract/core-publication-extension.json).
This is a local source candidate, with no release or deployment claim.

DiscussionBridge is a generic Discourse plugin for durable discussions shared
with publishing platforms. One forum can have any number of independent
Content Connections. Each connection represents one configured installation
of WordPress, Ghost, Statamic, Astro, publishing Discourse, or another future
adapter and manages many Bridge Records.

The plugin is default-disabled. Discourse remains authoritative for users,
topics, categories, tags, visibility, moderation, sessions, and replies.

The same plugin receives connected-platform content and creates local From
Discourse records for explicitly selected topics. An authorized platform adapter
retrieves those records and owns publication at its destination. The plugin does
not send topics to another forum or deploy content into a CMS.

Network is planned as an optional add-on requiring DiscussionBridge. Federation
is planned as an independent plugin for interforum relationships, sharing, and
participation. This core package contains neither add-on's runtime or Workspace
setup UI. Its v1 publication extension remains connection-scoped; it adds no
interforum membership, sharing or Network coordination API.

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
credited in the companion post. Mapping changes apply to future topics and,
when an adapter explicitly submits a new source-publication revision, its
managed topic. Legacy resolution and an exact revision retry do not reassign
existing topics. The operating identity remains separate from the visible
author. A legacy retry with the same external identity and URL returns the
same resource and topic without rewriting its first-published snapshot;
conflicting identity claims fail closed.

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

Legacy From Discourse reads retain inline cooked HTML and the legacy
`post:<id>:version:<n>` revision. The additive `source.edition` digest identifies
the coherent current title, body, native dates and source identity, including
grace-period edits that keep the same native post version. Upgraded adapters
use `edition` for freshness and retain resource/topic/binding identity. A title
edit may change the forum topic slug; it does not change the Bridge Record.
The response never includes another connection's record.

`source.created_at` and `source.updated_at` are the first post's actual native
creation and modification timestamps in UTC with six fractional digits. Core
title edits revise that first post. Replies and topic bumps do not change its
published edition or source-modified date. The effective `source.forum_name`
uses `DISCUSSIONBRIDGE_FORUM_NAME`, then `discussion_bridge_forum_name`, then
the native forum title. A supplied name must be nonblank valid UTF-8, at most
200 bytes, and free of control characters.

### Negotiated complete-content transport

Append `publication_contract=0.3.0-alpha.1` to inventory and single-record
detail requests. Active From Discourse metadata has `content_html: null`,
`source.status: "active"`, and `source.content` describing the complete cooked
HTML: byte count, SHA-256, resource-relative chunk path and `chunk_bytes: 32768`.
Metadata responses are bounded to 2 MiB. This is not a total publication limit.

```http
GET /discussion-bridge/v1/bridge-records/:resource_id/content.json?edition=<sha256>&offset=0
```

The same connection credentials and origin/direction/lane scope authorize
chunks. Each response provides `resource_id`, `edition`, `offset`,
`total_bytes`, `content_sha256`, `chunk_base64` and `next_offset` (null at EOF).
Decode base64 into bytes, join those bytes in offset order, verify the full
length and digest, then decode UTF-8; a multibyte character may cross chunks.
A changed edition returns 409 without content. Refresh that record's detail
and retry within the adapter's bounded retry policy. A changed inventory
snapshot returns 400, including an edit during page serialization.

Private categories, private messages, shared drafts, deleted/unavailable
sources, login-required forums and known imported external-source first posts
are ineligible for public export. Negotiated reads retain scoped record and
binding IDs with generic withdrawal metadata: `source.status: "withdrawn"`,
`reason: "source_unavailable"`, an opaque withdrawal edition and no body,
source author or content descriptor. Legacy reads and chunks fail closed.
Adapters use this explicit signal to withdraw their owned materialization and
retain its mapping. Eligibility restoration reuses the existing identity.
An absent inventory row does not authorize deletion.

### Explicit To Discourse source updates

Upgraded resolve requests may include `bridge_record.source_publication`:
`revision`, `previous_revision`, `created_at`, `updated_at`, `content_sha256`,
`content_bytes`, and `excerpted`. Revisions and digests are lowercase SHA-256;
the previous revision is null for creation or exact legacy adoption. Both date
keys are required but may be null when the source has no authoritative native
date. Strings require timezone-qualified ISO dates; no synchronization clock
is substituted. The ordinary HTML/request limits remain 48 KiB/64 KiB.

Without this object, resolve remains an identity-only legacy operation. With
it, exact retries compare the immutable source receipt and submitted title,
HTML and author identities, check native drift, and do not rewrite content.
A new revision requires the stored previous revision and an unchanged managed
native title/raw/author. It uses Core's revision and ownership permissions,
preserving the resource, topic, first post and binding. Human edits or a stale
precondition return reconciliation-required; ordinary synchronization never
overwrites them. Legacy adoption initializes a receipt only when the supplied
source exactly matches the managed native title, decorated raw and owner.

For an excerpt, the bounded HTML must include a canonical absolute **Read More**
link; full-source byte count and digest still describe the complete source.
Otherwise byte count and digest must match the submitted HTML. Responses add
`source_revision` and `source_publication_outcome` (`created`, `adopted`,
`updated`, `unchanged`) while retaining the existing resolve outcome.

## Forum-wide settings

- `discussion_bridge_enabled`
- `discussion_bridge_endpoint_enabled`
- `discussion_bridge_forum_name`
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

The optional **Presentation mode** selector offers Simple, Full and Interactive.
Its default uses the destination's existing selection. Omitting a mode when
republishing preserves existing source guidance; explicit null clears that
guidance, and an explicit canonical mode updates the same binding. Retrieval
reports the actual nullable `binding.presentation_mode`; updates do not force
Interactive or enable a rich-content template.

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

The candidate migration adds nullable `source_publication` metadata and nullable
binding `presentation_mode`. It performs no topic rewrite, backfill, enrollment,
publication or default activation. Persistent mappings and native discussion
data remain operator-owned when the plugin or connection is disabled or the
plugin is removed. Do not drop tables/columns as a source rollback step. A
rollback must coordinate matching consumer versions and preserve receipts and
the forum recovery point; full install/upgrade/rollback qualification remains
separate from the local author checks.

The plugin specs run inside a compatible Discourse checkout:

```bash
LOAD_PLUGINS=1 RAILS_ENV=test bundle exec rspec \
  plugins/discourse-discussion-bridge/spec
```

Generated plugin JavaScript must be rebuilt from current source before browser
system specs. Historical Alpha manifests and one-consumer acceptance records
are intentionally not part of this replacement product.

This candidate covers existing-record source export and explicitly revisioned
native updates. Operator Service enrollment/entitlements, automatic category
enrollment, publisher work/lease/acknowledgement/public-verification machinery,
topic-list delivery badges and end-to-end seven-profile qualification are not
implemented by these routes and are not completion claims for the Work List.

## License

See [LICENSE](LICENSE).
