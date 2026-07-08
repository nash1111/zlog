# SSR evaluation

Server-side rendering is not part of zlog's initial direction. zlog should remain a static-first generator unless a concrete use case proves that static output plus optional client enhancements cannot meet the requirement.

## Static-First Baseline

The default architecture is:

- local content input;
- deterministic `zlog check` and `zlog build`;
- static HTML, feeds, sitemap, search index, and assets;
- deploys to ordinary static hosts;
- no server runtime required for published sites.

SSR changes that operational model. It adds runtime hosting, request handling, cache invalidation, security surface, deployment variance, and production observability requirements.

## Use Cases That Could Justify SSR

SSR should only be reconsidered for specific needs such as:

- authenticated documentation where static access control is insufficient;
- request-specific content that cannot be prebuilt safely;
- very large generated sites where build-time rendering becomes impractical and caching can be proven simpler than static output;
- preview workflows that require per-request draft rendering and cannot be handled by `zlog dev`.

These cases must be backed by a real project requirement, not a general preference for server rendering.

## Static Alternatives To Try First

Before SSR, evaluate:

- static rebuilds with better incremental behavior;
- generated search indexes and client-side filtering;
- static route variants for versions, locales, and product editions;
- optional client widgets for interactivity;
- edge redirects or host-level rewrites that do not require zlog to run as an application server;
- separate preview tooling for drafts.

If one of these solves the use case, SSR should stay out of core.

## Required Design Questions

Do not start implementation until these questions have concrete answers:

- What data is request-specific?
- What cannot be pre-rendered?
- What deployment target is required?
- How are templates, plugins, and asset graphs loaded at runtime?
- How are cache keys and invalidation defined?
- How are errors reported without losing the current `check` and `build` diagnostics?
- How does SSR interact with RSS, sitemap, search index, and link validation?
- Can the static build continue to work unchanged?

## Decision Gate

SSR may move from future work to design only when:

- at least one real site needs it;
- the site cannot be reasonably served by static output plus optional client behavior;
- the runtime hosting model is identified;
- the security and caching model is documented;
- the implementation can remain isolated from the static generator path.

Until then, SSR remains explicitly deferred.
