# DiscussionBridge Operator service

DiscussionBridge Operator is an explicitly opted-in support role supplied by
one selected Operator service provider. The service may be paid or unpaid. It
does not make the operator a Discourse administrator or staff member, and it
does not control automatic publication synchronization.

## Provider model

Each forum can have exactly one selected Operator service provider and at most
one active Operator service enrollment. The receiver stores that provider on
its database-enforced singleton service record. A payment, provider request,
or remote event cannot select a provider or enable service.

The current Alpha catalog offers **DiscussionBridge Operator Service** from
**DiscussionBridge / WebSynergetics**. The administration page also identifies
**Approved Operator Partners** as planned. A future partner must be added to
the receiver's approved provider registry with its service-request address and
allowed operator email domain before it can be selected or receive a signed
entitlement. A provider cannot register, approve, or expand its own authority.

The selected provider is locked after the first enrollment request. A future
provider transfer must be an explicit, audited identity and entitlement
transition; it must not silently replace the bound operator.

## Enrollment

An administrator opens **DiscussionBridge → Operator service**, confirms the
single selected provider, and then turns on **Enable DiscussionBridge Operator
service**. This is local opt-in only: it does not submit a request or send a
notification. The administrator then separately selects **Request Operator
service**. The receiver records a stable installation ID and enrollment ID,
then queues one email to the selected provider's registry-controlled service
address. For the current first-party provider, that address is
`servicerequest@discussionbridge.dev`. The message contains the selected
provider ID, forum URL, installation and enrollment IDs, requesting
administrator username and email, plugin version, and timestamp. It contains
no forum credentials, Content Connection secrets, topic content, or user
census.

The switch is off by default. A payment or remote event cannot enable it. A
request cannot be submitted while the switch is off, and switching it on never
submits a request implicitly.

## Payment entitlement

The receiver accepts a signed entitlement at:

`PUT /discussion-bridge/v1/operator-entitlements/current.json`

The request body contains `entitlement.payload` and a base64-encoded
`entitlement.signature`. The payload is canonical JSON and is signed with
RSA/SHA-256. The receiver verifies it with the public key installed in the
server-only environment variable
`DISCOURSE_DISCUSSION_BRIDGE_OPERATOR_ENTITLEMENT_PUBLIC_KEY`.

New entitlements use schema 2. The exact payload fields are:

- `schema` — `2`
- `issuer` — `https://discussionbridge.dev/operator-service`
- `audience` — `discourse-discussion-bridge`
- `provider_id` — the exact provider selected locally before enrollment
- `installation_id`
- `enrollment_id`
- `entitlement_id`
- `operator_identity_id`
- `operator_email` — an address in the selected provider's approved registry
  domain; currently `@discussionbridge.dev`
- `identity_version`
- `entitlement_version`
- `plan_id`
- `status` — `active`, `past_due`, `cancelled`, or `revoked`
- `issued_at`
- `paid_through_at`
- `grace_period_days` — exactly `14`
- `grace_expires_at` — exactly 14 days after `paid_through_at`
- `site_url` — the exact forum base URL

Every field is signed. Provider, installation, enrollment, forum URL, issuer,
audience, provider-specific email domain, timestamps, grace policy, and
monotonic versions fail closed. Payment-state updates increment
`entitlement_version`. Replacing the operator identity also increments
`identity_version`.

Schema 1 remains accepted only as a compatibility form for the original
`discussionbridge` provider. The receiver normalizes it to that provider; it
cannot be used for an approved partner.

## Account binding

The entitlement supplies the approved operator identity and email address. The
receiver binds only an active, non-staged, non-system, non-suspended,
non-silenced local Discourse user with that exact email address. It does not
silently rewrite an existing user's email. An identity replacement is a new
versioned entitlement and a new local account binding; the old account loses
operator authority.

## Access states

- `active` — read and scoped mutation access.
- `past_due` before the paid-through time — read and scoped mutation access.
- `grace` — read and scoped mutation access for the fixed 14-day payment-failure
  grace period.
- `read_only` — status and operational records remain visible; all operator
  mutation actions are disabled.
- `cancelled` — remains mutable through the paid-through time, then becomes
  read-only without a grace period.
- `revoked` — no operator access. Security revocation is immediate.
- `inactive` or `pending` — no operator access.

Automatic synchronization, existing publications, Content Connections, and
administrator authority continue in every subscription state.

## Scoped capabilities

The operator may inspect publication health and work, inspect per-topic status,
set or clear per-topic publication overrides, synchronize a topic, retry failed
publication work, correct a presentation, and perform a verified publication
URL migration while mutation access is active.

The operator cannot create, update, disable, or delete Content Connections;
view or rotate credentials; change plugin or forum settings; manage users;
alter the entitlement; or otherwise administer Discourse.

Service enrollment changes, entitlement changes, identity changes, and scoped
operator mutations are recorded in the dedicated operator audit ledger.
