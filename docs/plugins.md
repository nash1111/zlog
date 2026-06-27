# Plugin Hook Notes

The core should stay small until the route, content, and asset model is stable.

The first plugin API should be limited to three hook families:

- `contentTransform`: receives parsed content and may return transformed Markdown or HTML.
- `routeEmit`: receives the route graph and may add generated routes.
- `assetEmit`: receives the asset graph and may add generated assets.

Plugins should not mutate unrelated global state. Hook execution order should be explicit in configuration, and every hook failure should report the plugin name, hook name, and source file that triggered the failure.

This document is a design note, not a stable API contract.
