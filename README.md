# DiscussionBridge for Discourse

DiscussionBridge is a generic Discourse plugin for durable discussions shared
with publishing platforms. One forum can have any number of independent
Content Connections. Each connection represents one configured installation
of WordPress, Ghost, Statamic, Astro, publishing Discourse, or another future
adapter and manages many Bridge Records.

The plugin is default-disabled. Discourse remains authoritative for users,
topics, categories, tags, visibility, moderation, sessions, and replies.

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
  rotate a secret. A new secret is shown once and is never returned by later
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
    "published": true,
    "visibility": "unlisted",
    "lane": "articles",
    "adapter_id": "publisher-adapter",
    "correlation_id": "delivery-1"
  }
}
```

Only exact boolean `published: true` is accepted. The connection must authorize
the direction, canonical origin, and lane. Forum policy selects the actor,
category, tags, and visibility. A retry with the same external identity and URL
returns the same resource and topic; conflicting identity claims fail closed.

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
- `discussion_bridge_effective_category_id`
- `discussion_bridge_effective_tags`
- `discussion_bridge_lane_policies`
- `discussion_bridge_default_visibility`
- `discussion_bridge_comments_only_full_interactive`

The endpoint and plugin switches are independently default-disabled. The
service user must be an active, non-system Discourse user. Configured category
and tags must already exist. Optional lane policy is forum-owned and fails
closed for missing or unknown lanes once configured.

## Presentation boundary

DiscussionBridge can qualify a healthy mapped topic for Discourse Core's
full-app embed. Core owns the iframe application, dynamic height,
authentication, composer, reply, quote, edit, Like, moderation, and session
behavior. The plugin only attests the exact Bridge Record/topic route and omits
companion post 1 from the mapped embed layout. The ordinary topic remains
unchanged.

No publishing-platform adapter is implemented inside this repository. An
adapter translates its platform lifecycle into the generic connection API and
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
