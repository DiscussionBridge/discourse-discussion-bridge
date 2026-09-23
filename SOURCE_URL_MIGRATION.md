# Source URL change for a platform-authored article

This procedure changes the URL of one existing **To Discourse** source item.
It is not a platform migration, replacement topic, or new Bridge Record.
The source content ID, connection, resource ID, topic, and replies remain the
same. The retired URL remains reserved against another item.

The receiver can independently prove the public redirect and destination
status, but not the native CMS post or page ID from HTTP alone. The operator
must confirm that the new route belongs to the same native item. The adapter
must subsequently resolve the same external ID, resource ID and topic ID;
Astro and Hugo also require the receiver's authenticated migration attestation
before changing their local canonical URL state.
If they were offline over more than one URL move, they require a contiguous,
connection-scoped history proof from their last known URL to the active URL;
a latest-move entry or an unrelated direct redirect is insufficient.

## Order of operations

1. Record the connection, platform content ID, resource ID, topic ID, old
   URL and installed adapter version. Back up the platform content and route
   configuration. Do not create a second platform item.
2. Change the URL of that **same** published item. Make the exact old HTTPS
   URL return a direct 301 or 308 to the exact working new HTTPS URL on the
   same origin. Confirm the new URL returns 200 and shows the expected item.
   A redirect chain, temporary redirect, cross-origin redirect, or a new page
   with a different native ID does not qualify.
3. In **DiscussionBridge → Bridge Records**, open the existing To Discourse
   record and use **Change source URL**. Check the displayed stable platform
   content ID against the native item, enter the new URL, and confirm it is
   the same item. The receiver
   verifies both public routes and checks connection scope, active ownership,
   historical URL reservations, record/topic health and Core embed identity
   before it updates the existing binding.
4. Retry or refresh the platform adapter. Check that it resolves the **same**
   resource and topic and that the platform page shows the same discussion.
   Confirm the retired URL still redirects. A rejected retry must be
   reconciled; it must never create a new content ID or topic.

The original topic first post retains its historical source link. That link
works through the permanent redirect. For a topic originally created by
Discourse Core embed and later adopted by DiscussionBridge, the receiver also
updates Core's embed URL to the new canonical source URL.

WordPress and Ghost use the same native post ID after a slug change. Statamic
uses the same entry ID; retry an already-delivered entry explicitly when
needed. Astro and Hugo source pages must keep their persisted DiscussionBridge
external ID; a URL-derived ID must first be pinned to its existing value.
Static sites must deploy their new page and redirect before this operation.

## Failed move and reverse move

If public verification or an ownership check fails, the receiver leaves its
binding unchanged. Repair the route or restore the original page and retry.
Do not edit Bridge database rows or create another record.

After a successful receiver move, do not silently restore the old route. To
reverse it, move the same native item back, reverse the public redirect so the
currently bound URL points directly to the restored URL, and run **Change
source URL** again with the current bound URL as old and the restored URL as
new. The receiver records a second verified move; adapters then retry the
same record and topic identity.

This is the source/contract procedure. It is not a claim that all supported
profiles have completed installed forward/reverse human replay.
