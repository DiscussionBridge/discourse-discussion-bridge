# DiscussionBridge for Discourse

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
  an authorized connection for external presentation.

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
for the authorized connection. It never includes another connection's record.

## Forum-wide settings

- `discussion_bridge_enabled`
- `discussion_bridge_endpoint_enabled`
- `discussion_bridge_service_username`
- `discussion_bridge_default_author_username`
- `discussion_bridge_effective_category_id`
- `discussion_bridge_effective_tags`
- `discussion_bridge_lane_policies`
- `discussion_bridge_default_visibility`
- `discussion_bridge_comments_only_full_interactive`

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
