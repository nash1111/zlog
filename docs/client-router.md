# Optional client router strategy

zlog should keep static HTML as the default output. A client router can be
explored as an optional enhancement, but it must not be required for
navigation, indexing, feeds, or deploys.

## Activation

The router should be disabled by default. A future site setting may opt in
after the generated HTML, route graph, sitemap, and search index all work
without it.

The router script should be emitted as a normal static asset and referenced only
when the opt-in setting is enabled.

## Navigation Flow

For eligible same-origin HTML links:

1. Fetch the target document.
2. Parse it as HTML.
3. Replace the current document title.
4. Reconcile managed `<head>` elements.
5. Swap the primary body content.
6. Update browser history.
7. Restore scroll and focus.

The router must ignore external links, downloads, new-window links, non-GET
interactions, hash-only links, unsafe query patterns, RSS, sitemap, search JSON,
and static assets.

## Head Policy

The router may update:

- `<title>`
- zlog-managed metadata
- canonical links
- stylesheet links that are absent from the current document

It should not remove unknown head elements owned by the user. Script execution
from newly fetched documents should be blocked unless a later design explicitly
defines script lifecycle hooks.

## Body Policy

The initial target should be the main content region. Full body replacement
should remain a fallback only when a layout cannot identify a stable content
boundary.

Body swaps should preserve the static fallback: reloading the target URL must
produce the same content without the router.

## Scroll and Focus

Hash navigation should scroll to the target element after the swap. Non-hash
navigation should scroll to the top unless the browser history entry has saved
scroll state.

After navigation, focus should move to the first heading in the new content or
to the main content container with `tabindex="-1"` if no heading exists.

## View Transitions

If the browser supports View Transitions, the router may wrap body swaps in
`document.startViewTransition`. If it does not, navigation should still work
with a normal DOM swap.

## Failure Mode

Any fetch, parse, validation, or swap failure should fall back to normal browser
navigation by assigning `location.href` to the target URL. Failed router
navigation must not leave the current page partially updated.
