# Why DiscussionBridge Has a Discourse Plugin

This document explains the plugin in product terms: why it exists, what it
adds to Discourse, what it deliberately leaves to Discourse Core and the Astro
adapter, and which attractive ideas were intentionally not implemented.

## The problem that motivated the plugin

DiscussionBridge began with the useful parts of Discourse's supported embed
system. A website could associate a page with a forum topic and display the
discussion. That was enough for read-oriented `simple` and `full` modes, and
those modes still work without this plugin.

The standard embed path was not enough for the intended `fullInteractive`
experience. In important states it displayed a **Start Discussion** or
**Continue Discussion** handoff instead of letting a signed-in reader reply,
Like, Quote, or edit inside the Astro page. It also did not provide the
forum-governed create-or-resolve control plane DiscussionBridge needed. Leaving
topic creation and policy entirely to each website would have exposed broad
forum credentials, duplicated topics under retries or races, and let a caller
choose forum-owned actors, categories, tags, or visibility.

The plugin was approved because the missing authority belongs inside Discourse.
It gives the forum a narrow control plane and a qualified comments-only
presentation while continuing to use Discourse Core for security-sensitive
forum behavior. It is not an attempt to fork or replace Discourse.

## What the plugin does

### Forum-governed create or resolve

For an authenticated, trusted request, the plugin can create or resolve the one
companion topic for a canonical source page. It:

- validates the trusted origin and dedicated connection credential;
- uses a configured non-`system` operating identity;
- applies forum-owned category, tag, lane, and visibility policy;
- defaults new Alpha topics to unlisted;
- reserves and stores the canonical mapping durably;
- resolves a retry to the existing mapping instead of creating a duplicate;
- fails closed when policy, identity, lane, or configuration is invalid; and
- records durable audit evidence without exposing the credential.

The creation endpoint is disabled at rest. It is enabled only for a bounded
creation window and is not a general posting API.

### Comments-only `fullInteractive` presentation

For a completed DiscussionBridge mapping, the plugin qualifies Discourse
Core's full-application embed and applies a narrowly scoped comments-only
presentation. The companion first post remains intact on the ordinary forum
topic but is hidden inside the comments iframe, avoiding duplication of the
Astro article.

Discourse Core supplies the actual composer, Reply, Quote, edit, Like,
authentication, sign-up, authorization, moderation, and post persistence. The
plugin adds only the integration needed to make that supported Core surface
honest and usable for the mapped discussion. It fails closed instead of
silently presenting the legacy handoff when Core full-app embedding and its
sign-in flow are not ready.

The plugin also makes the compact composer action explicit as **Post reply** or
**Save edit**, and narrowly contains Core's post-logout **Refresh** action so an
attested mapped child iframe reloads its mapped discussion instead of rendering
the forum homepage inside the website. It does not perform logout or session
cleanup.

### Operator evidence and bounded recovery

The plugin provides native administrator-only surfaces for:

- readiness and Health;
- searchable connection and audit evidence;
- reconciliation findings; and
- one bounded, auditable retry authorization for an eligible failed or stale
  reservation.

These surfaces favor diagnosis and explicit operator decisions. They do not
silently repair, delete, relist, retag, remap, or reassign authorship.

## What the plugin does not do

The plugin does not:

- install itself with the Astro package or rebuild a Discourse server;
- replace the Astro adapter, render Astro/Starlight pages, or own their table of
  contents;
- replace Discourse Core's composer, actions, authentication, accounts,
  sessions, authorization, moderation, or email behavior;
- provide or invent an embedded **Log Out** control that Core does not expose;
- give a website unrestricted forum API access;
- let adapter-supplied category, tag, actor, lane, or visibility values
  override forum policy;
- rewrite an ordinary topic or hide its first post outside the qualified mapped
  comments iframe;
- translate arbitrary MDX, Mermaid, math, or other component-heavy Astro
  content into Discourse;
- provision DNS, TLS, containers, databases, backups, snapshots, mail, or
  provider infrastructure;
- mutate production merely because a prerelease passed on sandbox or stable
  preproduction; or
- make `simple` and `full` modes depend on the plugin.

## Ideas deliberately declined for Alpha

Some ideas would make a demo look simpler while making the product less safe or
less honest. Alpha therefore does not implement:

- a plugin-owned composer or custom Reply, Like, Quote, edit, sign-in, sign-up,
  or logout system;
- synthetic logout UI or broad interception of generic **Refresh** controls;
- an always-open topic-creation endpoint;
- use of the privileged `system` user as the routine operating identity;
- caller-controlled forum policy;
- automatic reconciliation mutations;
- duplicate clone hooks, moving-branch installation, or in-container `git
  pull` upgrades;
- silent fallback from requested `fullInteractive` behavior to an external
  forum handoff; or
- rewriting a failed prerelease tag to make history look clean.

These are settled safety and authority boundaries, not missing checkboxes.

## Possible later work, not current promises

Later product work may consider richer reconciliation actions, broader trusted
or delegated posting, additional adapter families, configurable title
templates, and better summarization of component-heavy Astro/MDX content. The
plugin may also eventually justify a product identity broader than the
DiscussionBridge family.

None of those possibilities is an Alpha commitment. Each would require an
explicit product decision, an authority and security review, tests against the
exact supported Discourse revision, operator documentation, rollback evidence,
and a new immutable release candidate.

## The practical boundary

The Astro adapter knows the source page and asks for DiscussionBridge behavior.
The Discourse plugin knows forum policy and the durable page-to-topic mapping.
Discourse Core owns forum interaction and security. The administrator owns
installation, configuration, recovery, and promotion decisions.

That division is the reason the plugin exists—and the reason it remains
intentionally smaller than a replacement forum application.
