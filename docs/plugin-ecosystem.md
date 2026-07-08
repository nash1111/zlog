# External plugin ecosystem plan

An external plugin ecosystem should wait until zlog's core plugin hooks are stable. The first priority is a small local hook API; public distribution, compatibility promises, and third-party documentation should come later.

## Preconditions

Do not start external ecosystem work until:

- content, route, and asset hook shapes are implemented and used by at least one internal example;
- hook error reporting is stable;
- plugin ordering is explicit and tested;
- generated output remains deterministic;
- at least one release has shipped with the hook API marked experimental;
- there is evidence that external users need reusable plugins rather than local project hooks.

## Versioning Policy

When the ecosystem starts, plugin compatibility should be tied to a declared zlog plugin API version, not only the zlog binary version.

Recommended fields for future plugin metadata:

- `name`
- `version`
- `zlog_plugin_api`
- `hooks`
- `entrypoint`
- `description`
- `license`

Breaking hook changes should require a new plugin API version. zlog should reject plugins with unsupported API versions and report the plugin name, requested API version, and supported range.

## Compatibility Levels

Use explicit stability labels:

- `experimental`: API may change between minor releases.
- `preview`: API changes require migration notes.
- `stable`: breaking changes require a new plugin API version.

No public registry should accept plugins that target undocumented hook behavior.

## Documentation Requirements

Every external plugin should document:

- what hooks it uses;
- what files, routes, or assets it may read or emit;
- configuration shape and defaults;
- generated output examples;
- diagnostics and failure modes;
- compatibility range;
- security considerations when reading local files or running external tools.

## Distribution Boundaries

The initial ecosystem should prefer explicit local installation over automatic remote resolution. zlog should not download or execute remote plugin code during `check`, `build`, or `dev` without a separate, explicit design for trust and reproducibility.

Package registries, signed plugin manifests, lockfiles, sandboxing, and update workflows are separate projects. They should not block the core hook API, and they should not be added before a stable API exists.

## Decision Gate

Move from planning to ecosystem implementation only when:

- the hook API has at least one real internal consumer;
- compatibility policy is documented in release notes;
- plugin metadata has a schema;
- install and update behavior is reproducible;
- docs explain how to write, test, and publish a plugin without relying on private repository knowledge.
