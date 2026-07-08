# MDX and islands evaluation

MDX and islands are intentionally out of scope until concrete demand appears. zlog's default direction is a Zig-native static site generator that produces durable HTML without requiring a client runtime.

## What Would Justify Reopening

Consider MDX or islands only when at least one real site needs behavior that cannot be handled cleanly by Markdown, layouts, static assets, and small optional scripts.

Good candidates:

- API documentation that needs interactive examples beside prose.
- Product docs that need version selectors, live previews, or runnable snippets.
- Long-lived docs pages where a small interactive widget materially improves comprehension.

Weak candidates:

- Using JSX because it is familiar.
- Replacing ordinary Markdown components with a JavaScript component model.
- Adding a bundler only to share layout fragments.
- Competing with full application frameworks.

## Scope Boundaries

Any future design must preserve these defaults:

- `zlog build` still emits static files that work without JavaScript.
- Markdown remains the normal authoring path.
- Ziggy remains the native metadata format.
- RSS, sitemap, search index, and link validation do not depend on client-side hydration.
- The base binary does not require a Node package install.

If a feature violates those defaults, it should live in a separate layer or project rather than the core SSG.

## MDX Direction

MDX support should start as import or conversion tooling, not as the primary renderer. A safe first step would be a checker that reports which MDX constructs cannot be represented in zlog Markdown and layouts.

Questions to answer before implementation:

- Which component imports are required by real content?
- Can those components be represented as layout partials, callouts, code fences, or static embeds instead?
- How should frontmatter and heading extraction remain available to zlog without executing user JavaScript?
- What diagnostics should users see when MDX syntax cannot be converted?

## Islands Direction

An islands layer should be opt-in per page or per component and should not change server output semantics. The generated HTML should contain a static fallback first, then optional hydration metadata.

Questions to answer before implementation:

- What is the smallest runtime contract for a hydrated widget?
- How are widget scripts discovered, built, fingerprinted, and copied as assets?
- How are focus, accessibility, and progressive enhancement tested?
- How does the island interact with the optional client router strategy?

## Decision Gate

Do not start implementation until there is:

- at least one concrete site or example requiring the feature;
- a list of required interactive components;
- a fallback story for no-JavaScript browsing;
- a build strategy that does not make Node a default dependency;
- a migration plan that keeps existing Markdown content valid.

Until those criteria are met, keep MDX and islands as documented future work.
