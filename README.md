# zlog

`zlog` is a tiny Zig-native blog/static-site generator prototype based on the plan in `zig-blog-ssg-framework-plan.md`.

## MVP scope

Implemented now:

- `zlog init [dir]` scaffold with `zlog.ziggy`, `content/index.md`, `content/posts/hello.md`, `layouts/base.shtml`, and `layouts/post.shtml`.
- `zlog check [dir]` for config/frontmatter parsing, required title/date checks on posts, duplicate heading IDs, and broken internal Markdown links.
- `zlog build [dir]` for index, individual posts, tag pages, archive pages, RSS, sitemap, static assets, cmark-gfm Markdown rendering, `data-z-prefetch`, speculation rules, prefetch fallback runtime, and cross-document view-transition CSS.
- `zlog dev [dir] [port]` to serve the generated `public/` output on localhost and rebuild when project files change.

Not implemented yet: external SuperHTML integration, live reload overlay, image dimension probing, plugin ecosystem, SSR, MDX, islands, or client router.

## Build and test

This MVP is currently verified with Zig 0.16.0.

```bash
sudo apt-get install libcmark-gfm-dev libcmark-gfm-extensions-dev
zig build test
zig build
zig build release-local
./zig-out/bin/zlog --help
```

If Zig is not installed locally, install a recent Zig release first.
Release artifact naming and packaging are documented in `docs/releases.md`.

## Usage

```bash
zig build
./zig-out/bin/zlog init my-blog
./zig-out/bin/zlog check my-blog
./zig-out/bin/zlog build my-blog
./zig-out/bin/zlog dev my-blog 1111
```

The generated site is written to `public/` by default.

Site-wide metadata lives in `zlog.ziggy`:

```ziggy
.title = "example.dev",
.url = "https://example.dev",
.language = "en",
.timezone = "UTC",
.author = "Example Author",
.permalink = "/posts/:year/:month/:slug/",
.page_size = 10,
```

RSS and sitemap output use `.url` for absolute URLs. RSS, generated metadata, and templates can also consume `.language`, `.timezone`, and `.author`.
Post URLs use `.permalink`; supported placeholders are `:slug`, `:year`, `:month`, and `:day`.
Listing pages use `.page_size`; additional index, tag, and archive pages are generated as needed.

`zlog dev` watches `zlog.ziggy`, `content/`, `layouts/`, and `static/`, then runs a full rebuild when any watched file changes. Existing output stays served if a rebuild fails.

## Frontmatter

Ziggy-like frontmatter is supported for the MVP:

```md
---
.title = "Hello zlog",
.slug = "hello-zlog",
.date = "2026-06-23T00:00:00+09:00",
.updated = "2026-06-24T00:00:00+09:00",
.tags = ["zig", "ssg"],
.categories = ["Engineering"],
.series = ["Building zlog"],
.layout = "post.shtml",
.draft = false,
.prefetch = "hover",
.transition = "post-title:hello",
---

# Hello
```

## Draft content

Set `.draft = true` to keep a page or post out of production output. Draft
content is skipped when writing HTML pages and is also omitted from index, tag,
archive, RSS, and sitemap output.

The current `zlog dev` command rebuilds and serves the same production output
path on localhost, so it does not publish drafts locally. A future preview mode
can add an explicit draft flag without changing production behavior.

## Template attributes

Layouts are rendered as validated HTML with explicit `z-*` template attributes:

- `z-text="binding"` replaces an element body with escaped text.
- `z-html="binding"` replaces an element body with trusted rendered HTML.
- `z-replace="binding"` replaces the whole element with trusted rendered HTML.
- `z-attr:name="binding"` writes an escaped attribute when the binding is not empty.

Supported bindings are `site.title`, `page.title`, `page.full_title`,
`page.date`, `page.transition`, `page.tags`, `page.taxonomies`, `content`,
`post_list`, `pagination`, `pagination.current`, `pagination.total`,
`pagination.previous_url`, `pagination.next_url`, `zlog.head`, and
`zlog.runtime`. `z-replace="page.taxonomies"` inserts links for tags,
categories, and series. `z-replace="pagination"` inserts generated pagination
navigation when a listing spans multiple pages. Legacy `{{...}}` tokens are
rejected during template rendering.

## Navigation hints

Generated pages include:

- `@view-transition { navigation: auto; }` CSS.
- `script type="speculationrules"` rules for `tap` and `hover` links.
- a tiny JS fallback for `hover`, `tap`, `viewport`, and `load` prefetch values.
