# Release Artifacts

zlog is intended to ship as standalone binaries for Linux and macOS.

## Local Builds

```bash
zig build -Doptimize=ReleaseSafe
```

The binary is written to `zig-out/bin/zlog`.

## Target Matrix

Initial release artifacts should cover:

- `x86_64-linux`
- `aarch64-linux`
- `x86_64-macos`
- `aarch64-macos`

## Packaging

Each artifact should be a compressed archive with this shape:

```text
zlog-{version}-{target}/
  zlog
  README.md
  LICENSE
```

## Validation

Before publishing a release, run:

```bash
zig fmt --check build.zig src/main.zig
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zlog check examples/blog
./zig-out/bin/zlog build examples/blog
```

Release automation can use the same commands before uploading archives.
