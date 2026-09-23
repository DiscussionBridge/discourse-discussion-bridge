# DiscussionBridge Operator service

DiscussionBridge Operator is an explicitly opted-in, payment-controlled support
role. It does not make the operator a Discourse administrator or staff member.
It does not control automatic publication synchronization.

## Enrollment

An administrator opens **DiscussionBridge → Operator service** and first turns
on **Enable DiscussionBridge Operator service**. This is local opt-in only: it
does not submit a request or send a notification. The administrator then
separately selects **Request Operator service**. The receiver records a stable
installation ID and enrollment ID, then queues one email to
`servicerequest@discussionbridge.dev`. The message contains the forum URL,
installation and enrollment IDs, requesting administrator username and email,
plugin version, and timestamp. It contains no forum credentials, Content
Connection secrets, topic content, or user census.

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

The exact payload fields are:

- `schema` — `1`
- `issuer` — `https://discussionbridge.dev/operator-service`
- `audience` — `discourse-discussion-bridge`
- `installation_id`
- `enrollment_id`
- `entitlement_id`
- `operator_identity_id`
- `operator_email` — a DiscussionBridge-controlled `@discussionbridge.dev`
  address
- `identity_version`
- `entitlement_version`
- `plan_id`
- `status` — `active`, `past_due`, `cancelled`, or `revoked`
- `issued_at`
- `paid_through_at`
- `grace_period_days` — exactly `14`
- `grace_expires_at` — exactly 14 days after `paid_through_at`
- `site_url` — the exact forum base URL

Every field is signed. Installation, enrollment, forum URL, issuer, audience,
email domain, timestamps, grace policy, and monotonic versions fail closed.
Payment-state updates increment `entitlement_version`. Replacing the operator
identity also increments `identity_version`.

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
