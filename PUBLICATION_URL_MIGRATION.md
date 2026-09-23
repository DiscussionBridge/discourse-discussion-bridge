# Publication URL change

This is an operator-assisted cutover for an existing **native From Discourse**
publication. It is not a connection change, a new platform content ID, or a
second Bridge Record. The Bridge retains the active binding, resource ID, topic
and discussion. The old URL becomes reserved history.

The receiver can prove public routing, not page authorship. Before using the
**Change publication URL** action, an operator must verify that the new page
is the intended platform record and still shows the same Discourse topic and
Bridge discussion. Do not use an unrelated page merely because it returns 200.

## Cutover order

1. Record the existing connection, platform content ID, resource ID, topic ID,
   old URL, and deployment identity. Back up the platform content and routing
   configuration. Pause platform publication synchronization during cutover.
2. Move the *same* platform record to its intended native URL. Do not create a
   replacement record. Install a permanent old-to-new redirect (301 or 308)
   on that platform's hosting layer. Keep it live for existing links.
3. Verify the new public URL returns 200 and renders the expected content,
   resource and discussion. Verify the exact old URL returns 301 or 308 with
   `Location` resolving directly to the exact new URL. A temporary redirect,
   redirect chain, missing destination or changed origin is not sufficient.
4. In **The Bridge → DiscussionBridge → Publishing**, find that publication,
   select **Change publication URL**, enter the new URL, and select **Verify
   redirect and change URL**. The receiver independently checks the live HTTP
   responses before it changes the binding.
5. Reopen the new page, check the same topic and replies, run an exact adapter
   retry/synchronization, and confirm it resolves the existing record without
   a duplicate. Confirm the old URL still redirects. Resume normal delivery.

Both URLs must be HTTPS on the same configured origin. The receiver checks
within the Content Connection's allowed origin and rejects collisions with
active bindings or reserved prior URLs. The HTTP check uses Discourse's
SSRF-filtered connection path; it does not follow a redirect chain or download
the page body. Its proof is point-in-time: keep monitoring the redirect after
the cutover.

## Host-specific redirect preparation

- **Astro or Hugo on Cloudflare Workers:** the adapter's source-only
  `migrate-publication` command moves the resource-owned Markdown file and
  prepares a `_redirects` 301 entry. Review the diff, build and deploy the
  static output, then verify the public Worker route before changing The Bridge.
- **Statamic SSG on Cloudflare Workers:** update the authoritative Statamic
  entry and generate new static output; stage a `_redirects` rule in the
  deployed static bundle. An authoring-app route does not configure the Worker.
- **Statamic Flat or DB served dynamically:** move the same entry and add a
  host/application permanent redirect. Verify the public site, not merely the
  Control Panel preview.
- **WordPress:** Core's old-slug redirect is useful only for supported post
  slug changes. For other permalink changes, provision an explicit host or
  application redirect. Verify the installed route and post ID.
- **Ghost:** update the same Ghost post and install an explicit 301 in
  `redirects.yaml` or the host proxy. Verify the post ID and public route.

These are preparation patterns, not a claim that every hosting provider has
been replayed. Do not rely on a configured rule without checking the HTTP
result from outside the platform.

## Older publications

Records created before native-publication classification may instead show
**Verify older publication and change URL**. The operator must verify that
the new page is the same platform record and still displays this Discourse
topic, then type the exact platform content ID and confirm that observation.
The receiver also requires the same permanent-redirect proof. Only after all
checks pass does it update the URL and mark the existing binding as native in
one transaction. A failed check leaves both fields unchanged. Do not use
**Edit presentation** as a shortcut for an actual page move.

## Failure and rollback

Before the receiver accepts the migration, it still expects the old binding.
If the page move or redirect check fails, restore the original page and route
from the platform backup, leave the receiver binding unchanged, and retry only
after both URLs behave as intended. A rejected migration does not create a
second Bridge Record or consume the new URL.

After the receiver accepts the migration, **do not simply restore the old page
or remove the redirect**. That would leave the forum binding pointing at the
new URL. Keep the new page and redirect in place while investigating. To
return to the previous URL, move the **same** platform record back, reverse
the permanent redirect so the currently bound URL points to the restored URL,
verify both public routes and the resource/topic again, then run **Change
publication URL** with the currently bound URL as old and the restored URL as
new. This records a second verified move on the same binding. If the hosting
layer cannot safely reverse the redirect, keep the current URL and escalate;
do not edit database rows or create another publication.

This procedure is source documentation pending exact-package CI and
human-operated sandbox replay. It is not evidence that a live migration has
already occurred.
