# Plugin hook API design

This is a design contract, not a stable public API. The goal is to keep zlog
extensible without moving core behavior behind premature abstractions.

## Scope

The first plugin API should be limited to three hook families:

- `contentTransform`: receives one parsed content page before Markdown
  rendering and may return transformed Markdown. It must not change the page
  route directly.
- `routeEmit`: receives the completed `RouteGraph` after core routes are known
  and may add generated routes.
- `assetEmit`: receives the completed `AssetGraph` after core assets are known
  and may add generated assets.

Hooks run only during local `check`, `build`, and `dev` rebuilds. The generated site remains static file output.

## Ordering

Plugins run in the explicit order configured by the site. A plugin's hooks run in build-phase order:

1. `contentTransform`
2. core Markdown rendering, route graph construction, and validation
3. `routeEmit`
4. asset graph construction
5. `assetEmit`
6. final validation and file writes

zlog should not sort plugins by package name, discovery order, or filesystem
order. Missing ordering information is an error once plugins are enabled.

## Error Reporting

Every hook error should include:

- plugin name
- hook name
- source file or generated route being processed when available
- original error message

Hook failures should stop the build unless a future hook explicitly declares
recoverable diagnostics.

## Boundaries

Plugins should receive narrow context objects instead of global mutable state.
They may add or transform the artifact owned by their hook, but they must not
mutate unrelated pages, routes, assets, or site configuration.

The first implementation should prefer static linking or explicit local modules
over network-loaded plugins. Remote plugin resolution, package registries,
background installs, and sandboxing are out of scope for this design.
