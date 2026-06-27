# Release Artifacts

zlog release artifacts are compressed directories built by the `release-local`
build step. The step always compiles the release executable in `ReleaseSafe`
mode for the selected target.

## Local Release Build

```bash
zig build release-local
```

The step writes:

```text
zig-out/releases/zlog-0.1.0-{arch}-{os}/
  zlog
  README.md
  RELEASES.md
zig-out/releases/zlog-0.1.0-{arch}-{os}.tar.gz
```

For example, a native x86_64 Linux build produces:

```text
zig-out/releases/zlog-0.1.0-x86_64-linux.tar.gz
```

## Target Matrix

Initial release automation should produce these artifacts:

- `zlog-0.1.0-x86_64-linux.tar.gz`
- `zlog-0.1.0-aarch64-linux.tar.gz`
- `zlog-0.1.0-x86_64-macos.tar.gz`
- `zlog-0.1.0-aarch64-macos.tar.gz`

Because Markdown rendering links against `cmark-gfm`, each release runner must
provide `libcmark-gfm` and `libcmark-gfm-extensions` for the selected target.
The same `release-local` step can run on Linux and macOS runners; cross builds
need matching target libraries or a sysroot.

## Validation

Before publishing a release, run:

```bash
zig fmt --check build.zig src/main.zig test/cli_integration.zig
zig build test
zig build release-local
./zig-out/bin/zlog check examples/blog
./zig-out/bin/zlog build examples/blog
```

GitHub Actions can later run those commands in a target matrix, then upload the
generated `zig-out/releases/*.tar.gz` files.
