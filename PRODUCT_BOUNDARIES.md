# DiscussionBridge product boundaries

## This plugin owns

- generic Content Connection identity, independent credentials, scope, and
  enabled state;
- plugin-issued Bridge Record identity and one-topic continuity;
- active, prepared, and historical external bindings;
- authenticated create-or-resolve for authoritatively published content;
- forum-owned operating identity, forum-default author, per-connection fixed or
  mapped-source publication author, source-author mappings, category, tag,
  visibility, and lane policy;
- idempotency, collision rejection, persistence, audit, and reconciliation;
- native Discourse administration for Overview, Connections, Bridge Records,
  migration, and Reconciliation;
- authorized retrieval of From Discourse content by the relevant connection;
- local publication of an existing Discourse topic as a From Discourse record
  for one or more independently authorized platform connections;
- exact mapped-topic attestation for optional comments-only full-app
  presentation, including an explicit From Discourse source-presentation mode
  that omits the already-rendered first post while retaining its replies.

## Discourse Core owns

- users, authentication, sessions, logout, account creation, and authorization;
- topics, posts, moderation, composer, reply, quote, edit, Like, and deletion;
- ordinary topic presentation and full-app embed behavior;
- dynamic iframe sizing and Core accessibility behavior;
- category, tag, visibility, mail, backup, restore, and server operation.

## Publishing adapters own

- platform publish lifecycle and the proof that content is authoritatively
  published;
- platform-specific credentials, hooks, installation, and UI;
- canonical external identity and URL supplied to the connection;
- bounded source-author identities, display names, optional same-origin profile
  URLs, and the single primary source author supplied to the connection;
- a bounded published-content HTML snapshot suitable for Discourse's ordinary
  post cooking and sanitization pipeline;
- server-side storage of the one-time DiscussionBridge connection secret;
- rendering, linking, or embedding the returned discussion through the
  platform's supported mechanisms;
- durable storage of the plugin-issued resource and topic identities where
  required by that platform.

This plugin is designed to receive compatible adapters for WordPress, Ghost,
Statamic, Astro, and future platforms. A publishing Discourse installation uses
this same plugin to create local From Discourse records; it does not transmit
ordinary publications to a second forum. It does not claim
that those adapters exist merely because their platform type is available when
an administrator creates a connection.

## Product invariants

- One forum supports zero or more connections.
- One platform type may have many independent connections.
- One connection may have many Bridge Records.
- Direction belongs to a Bridge Record, not a connection.
- A To Discourse record has one active source binding.
- A From Discourse record has one active presentation binding.
- One Discourse topic may have independent From Discourse records for multiple
  platform connections.
- A Bridge Record preserves its resource and topic identity during migration.
- A connection can read only records bound to that connection.
- One primary source author may select the topic owner through a
  connection-scoped mapping; all supplied source authors remain credited.
- Source-author mappings affect future topic creation and never silently
  transfer ownership of an existing topic.
- Draft, malformed, unauthenticated, out-of-origin, out-of-lane, and conflicting
  requests fail before topic creation.
- Secrets never appear in read APIs, health output, support bundles, logs, or
  client configuration.
- Loading an ordinary publishing page does not itself authorize topic creation;
  only its server-side adapter may call the authenticated endpoint after the
  platform has established publication.

## Explicitly excluded

- the rejected v1 control plane, Bridge Spaces, deployment brokers, signed plan
  estates, receipt chains, or platform-wide orchestration;
- embedding Astro-specific build, routing, frontmatter, CLI, import, or
  navigation code in the Discourse plugin;
- implementing WordPress, Ghost, Statamic, or Astro adapters inside this
  repository;
- product, release, deployment, publication, provider, or risk acceptance;
- replacing Discourse Core security-sensitive interaction behavior.
- user synchronization, login federation, account provisioning, or treating
  source-author mapping as Discourse authorization.
