# zlog

`zlog` is a tiny Zig-native blog/static-site generator prototype based on the plan in `zig-blog-ssg-framework-plan.md`.

## MVP scope

Implemented now:

- `zlog init [dir]` scaffold with `zlog.ziggy`, `content/index.md`, `content/posts/hello.md`, `layouts/base.shtml`, and `layouts/post.shtml`.
- `zlog check [dir]` for config/frontmatter parsing, required title/date checks on posts, duplicate heading IDs, and broken internal Markdown links.
- `zlog build [dir]` for index, individual posts, tag pages, archive pages, RSS, sitemap, static assets, cmark-gfm Markdown rendering, `data-z-prefetch`, speculation rules, prefetch fallback runtime, and cross-document view-transition CSS.
- `zlog dev [dir]` as a minimal rebuild-once development command placeholder.

Not implemented yet: real SuperHTML/Ziggy integration, incremental file watching, live reload overlay, image dimension probing, plugin ecosystem, SSR, MDX, islands, or client router.

## Build and test

This MVP is currently verified with Zig 0.16.0.

```bash
sudo apt-get install libcmark-gfm-dev libcmark-gfm-extensions-dev
zig build test
zig build
./zig-out/bin/zlog --help
```

If Zig is not installed locally, install a recent Zig release first.

## Usage

```bash
zig build
./zig-out/bin/zlog init my-blog
./zig-out/bin/zlog check my-blog
./zig-out/bin/zlog build my-blog
```

The generated site is written to `public/` by default.

## Frontmatter

Ziggy-like frontmatter is supported for the MVP:

```md
---
.title = "Hello zlog",
.date = "2026-06-23T00:00:00+09:00",
.tags = ["zig", "ssg"],
.layout = "post.shtml",
.draft = false,
.prefetch = "hover",
.transition = "post-title:hello",
---

# Hello
```

## Template tokens

The MVP uses small HTML-first token replacement instead of a full SuperHTML renderer:

- `{{site.title}}`
- `{{page.title}}`
- `{{page.date}}`
- `{{page.tags}}`
- `{{content}}`
- `{{post_list}}`
- `{{zlog.head}}`
- `{{zlog.runtime}}`

## Navigation hints

Generated pages include:

- `@view-transition { navigation: auto; }` CSS.
- `script type="speculationrules"` rules for `tap` and `hover` links.
- a tiny JS fallback for `hover`, `tap`, `viewport`, and `load` prefetch values.
