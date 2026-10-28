# DiscussionBridge for Discourse — V4 development candidate

Working package `0.4.0-alpha.1`, wire `v4`, candidate
`discussionbridge-v4-core-20261025-r6`, release version null. This is an unpublished
implementation candidate, not an exact-approved or frozen release. Native
Discourse, PostgreSQL migration and browser qualification remain incomplete.

One generic plugin artifact serves every installation. Installation-specific
runtime patches and per-forum product forks are prohibited. Supported native
configuration controls independent Content Connections, origins, directions,
lanes, author mappings and publication policy. The plugin is disabled by default.
Discourse remains authoritative for native users, topics, posts, discussions,
moderation, sessions and Guardian permissions.

The single shared API is the 36 declared `/discussion-bridge/v4/` routes. Its
pinned normative source and derived schema are packaged in
`lib/discussion_bridge/cms_contract.json` and `cms_protocol_types.json`. There are
no earlier development wire routes, version selectors, receiptless initialization,
old record conversion or MappingAdopt interface. Native Core TopicEmbed association
and Simple, Full and Interactive discussion presentation are retained functions.

Native publishing uses `/admin/publishing` and its topic/publication actions.
Protected CMS configuration, delivery, preview and stored catalog controls use
`/admin/content-connections/:id/cms-*`. Native session, CSRF, XHR, staff/admin and
Guardian requirements remain distinct from Content Connection credentials.
Only an explicit administrator create/rotate response can transiently display and
copy the newly issued secret; later reads and public/support output exclude it.

Native publication status reports `presentation_mode` as the validated current
desired selection, matching Mapping and preview. `initial_presentation_mode` is
the binding's creation-time selection. Neither field proves the mode was applied;
delivery status and its retained policy revision remain separate evidence. An
unavailable current configuration yields a null current mode rather than falling
back to the historical selection. Status reads never rewrite the binding.

Current To publication carries complete source hash/count with either full HTML
or the explicit owned generated excerpt. Generated Read More follows a verified
new canonical URL through a fresh revision and atomic owned native-segment edit;
article content, historical attribution footer, native/resource/topic identities
and prior receipts remain intact. The exact source-public proof mechanism and
SourceHTML execution/URI/provider/fallback/default/true-absence rules remain
unresolved; typed reported fields alone are not native/public execution evidence. Current From snapshots
retain complete native cooked content and bounded internal transport pagination.
The narrow math converter preserves mixed links/media/captions on the native HTML
path. Actual downstream rich media/provider rendering still needs qualification.

Preparation preserves the complete article meaning and the native original.
Copied relative navigation/media references use the captured source article URL.
To complete prepared-source evidence is measured after this resolution and before
excerpt selection. From transport integrity covers the exact immutable cooked
source input: a recipient verifies the complete count/hash first, then prepares
the copy against the edition-captured `Source.topic_url` before native-output
evidence or excerpting. Source integrity and native-output fingerprints differ.
Accepted editions, exact pending requests and history are not reprepared using a
later URL. Canonical-only moves retain article bytes except the owned Read More.

Unformatted text and nontext are valid source content. Missing supported cooked
output is reported as a Bridge preparation limitation/attention, not source
ineligibility. The current native converter supports ordinary HTML link/media
attributes and responsive image URL tokens; it reports unsupported relative CSS,
CSS escape/import, document-base overrides, unknown relative element reference
contexts and URI syntax rather than silently changing their targets. This is
converter capability, not a content/safety/provider allowlist. Native components,
embeds and active functionality require actual native qualification; retaining
the original does not prove an equivalent working copy. A specific unsupported
function must be reported for operator choice, not silently removed or treated
as equivalent to a link/caption.

New native publication/revision compares the source's parsed facilities and
nonempty data with the actual cooked post inside the existing transaction before
acceptance. Observed script/data, handler, form/control/disclosure and media
structure/target losses, or unavailable required native rendered-article evidence,
stop acceptance with Phil's approved `content_preservation_unavailable` code
(HTTP422, nonretryable). This applies to To resolve and the owned Read More native
edit before its receipt/reservation commit; metadata failures keep their existing
meaning. This is structural evidence, not browser-function equivalence or a
ban/permission based on content type. Escaped displayed code remains content;
actually retained native players, disclosures and component data are compared
without an assumed Core-default rejection. Exact accepted replay is not recooked.

Specific item diagnostics use the existing native `Rails.logger.warn` facility,
JSON event `discussion_bridge_native_content_loss`. An authorized server operator
can read/search that event in the installation's configured Rails/Discourse server
log through existing protected operational access. It records connection ID,
external ID, source revision, supplied correlation ID, mutation ID, diagnostic kind
(`article_unavailable` versus `observed_content_loss`) and structural loss names/
counts. Move diagnostics include the actual resource ID and no fabricated request
correlation. It never includes program/data bodies, values/hashes, URLs,
credentials or request trees. No log file path, native administrator log-screen
availability, retention/durability or deployment access is asserted here. The wire
response and browser popup remain the closed code. Unknown equivalent component
transforms and later native cooking/jobs/browser changes require actual native
qualification; a stored original or raw fingerprint does not establish them.

Native presentation correction records a private pending intention. The old URL
remains authoritative until the actual native move and public proof settle it.
Only an eligible explicit administrator request may create the separate audited
publication cycle; it preserves the previous verified work, source and policy.
A saved intention is not a CMS mutation or successful publication. Global disable
retains a private same-intent hold so restoring gates cannot automatically recreate
that cancelled intent. Protected native attention recovery uses two explicit actions: Check native state,
then Retry ready selected (or an individual Retry). Factual native reports only
classify retained observations; neither their completion nor restored selected
metadata automatically restarts attention. Closed capability attention-recovery-1
and V4-32 through V4-36 provide inspection/report and exact positive successor
handoff. General claims cannot take recovery successors. Native actions require
the current administrator, Guardian access, current connection/source/policy/
selected IDs and an unchanged bound context. Independent selected outcomes are
bounded to25. Exact native action UUID/body receipts are retained; the panel reuses
an uncertain action's UUID on an explicit repeat while the panel remains mounted.
A later explicit repeat is also protected by unique predecessor lineage.

An admitted retry appends fresh UUID/cycle attempt0 Work, supersedes the old
attention and protects its encrypted pretransition snapshot/history. It retains
the fence floor; the exact successor claim raises mapping authority monotonically.
The exact same-Work static preparation may be settled only by the named Settle
restored baseline and retry action after actual native AND public baseline proof.
An older preparation owned by another Work/source/policy is Not ready/context_changed
before inspection creation; it is preserved for a separate recovery decision.
Applied prepared-static candidates, missing verified baselines, applied URL
rebinding and cancelled same-intent holds are not admitted by this mechanism.
Known VERIFIED withdrawn baselines retain their actual prior native ownership
receipt source revision, which can remain the earlier published source while
receiver synchronized/public revisions are null. Retained native objects require
current revision/managed-content and owned manifest readback. Only Hugo currently
supplies a qualified complete owned-all-absent native manifest; deleting a known
Astro or Statamic draft remains a conflict. Static recovery requires both the
retained prior verified absence proof and a new exact-URL anonymous absence read.
Dynamic proof remains optional where applicable and exact when supplied. No
cross-host clock threshold or TTL is invented. A known current dynamic candidate
after withdrawal can bind that exact prior verified withdrawal receipt and prior
absence proof while retaining all current candidate/source/content checks; it
is not relabelled as an unchanged baseline or an applied static adoption.

Receiver native IDs remain their last acknowledged values; a known applied
first-create candidate carries its observed ID in the positive native baseline,
which its native owner must retain instead of creating another object.

Actual attention occurrences create durable, deduplicated native bell deliveries
for current active nonstaged nonsuspended administrators, rechecked at delivery.
The bell contains only a generic label and the protected native connections panel
link, uses Core's supported no-email flag, and leaves normal read/unread behavior.
Notification transport failures retain pending outbox rows and bounded diagnostics;
they do not restart Work. There is no restoration/completion bell or SMS. Native
DB/migration/Sidekiq/Ember/browser qualification of this new mechanism remains a
separate unexecuted gate. Support-access mechanisms remain unresolved.

## New-baseline upgrades and recovery

The initial migration creates a fresh transactional V4 baseline. It performs no
conversion of earlier development deployments. Future V4 upgrades must preserve
native/resource/topic/discussion IDs, ownership/configuration, schema data,
exact pending request trees and CAS, leases/fences, encrypted receipt keys,
immutable history, URL reservations and tombstones. Local encryption format 1 is
a durable private format, not an earlier wire API.

Before an upgrade or rollback, establish protected, matching database,
configuration/key and upload recovery points and record the actual restore
evidence for that installation. Coordinate receiver and consumer artifact/runtime
state and stop conflicting workers. A source/plugin rollback that retains schema
and durable state differs from destructive Rails schema down. This baseline
refuses automatic down/data deletion. Recover only from a protected matching
state whose real restore has been established; do not invent backup paths or
claim installation qualification from these instructions. Package copying,
syntax/value checks and prose do not establish migration or recovery acceptance.

## Available author checks

`spec/scripts/v4_codec_checks.rb` exercises current value/codec rules and reference
parity. `spec/scripts/v4_package_checks.rb` checks pinned artifacts, declared route
assembly, loader members and Ruby syntax. Native examples cover source eligibility,
mixed-content preservation and publishing transactions. These author checks are
not native build, rendering, authentication, database, formal review or release
qualification. The focused attention scripts are attention_recovery_checks.rb,
attention_notifications_checks.rb, attention_withdrawn_baseline_checks.rb,
attention_admin_controls_checks.mjs and
attention_notification_renderer_checks.mjs. They exercise actual method paths
with declared synthetic persistence/framework/transport seams. The retained native
Discourse runtime has historical qualification for earlier scopes; no native
Rails/PostgreSQL/Ember execution of this new attention feature is asserted by
these local scripts or those prior results.
