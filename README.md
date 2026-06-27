# zlog

zlog is a Zig-native static site generator for small blogs and documentation sites.

It builds Markdown content into static HTML, tag pages, category pages, archive pages, RSS, sitemap, and a JSON search index. The core build and check commands only use local file input and output.

## Install

Build from source with Zig 0.16.0:

```bash
zig build -Doptimize=ReleaseSafe
```

The binary is written to:

```bash
zig-out/bin/zlog
```

## Quickstart

```bash
zig build
./zig-out/bin/zlog init my-site
./zig-out/bin/zlog check my-site
./zig-out/bin/zlog build my-site
```

The generated site is written to `public/` by default.

For local browser preview after a build, use the helper script:

```bash
python3 tools/preview_static.py my-site/public --port 8000
```

The preview script is intentionally separate from the `zlog` binary.

## Commands

```bash
zlog init [dir]
zlog check [dir]
zlog build [dir]
zlog dev [dir]
```

- `init` creates a starter site.
- `check` validates content schema, internal links, duplicate heading IDs, duplicate transition names, and generated HTML structure.
- `build` writes static output.
- `dev` rebuilds once, then watches local files and rebuilds on change. It does not start an HTTP server.

## Configuration

Configuration lives in `zlog.ziggy`.

```zig
.title = "example.dev"
.url = "https://example.dev"
.language = "en"
.timezone = "UTC"
.author = "Example Author"
.content_dir = "content"
.layouts_dir = "layouts"
.out_dir = "public"
.permalink = "/:slug/"
.page_size = 10
.prefetch_default = "hover"
.speculation_rules = true
.search_index = true
```

Important fields:

- `url`: used for absolute RSS and sitemap URLs.
- `permalink`: supports `:slug`, `:year`, `:month`, and `:day`.
- `page_size`: controls listing pagination.
- `prefetch_default`: one of `hover`, `tap`, `viewport`, `load`, or `false`.

## Frontmatter

zlog uses Ziggy-style frontmatter as the native format. A small YAML-style import path is also accepted for migration.

```md
---
.title = "Hello zlog"
.description = "A first post."
.date = "2026-06-27"
.updated = "2026-06-27"
.slug = "hello-zlog"
.tags = ["zig", "ssg"]
.categories = ["notes"]
.layout = "post.shtml"
.draft = false
.prefetch = "hover"
.transition = "post-title:hello"
---

# Hello
```

Draft posts are excluded from production builds.

## Markdown

The built-in renderer supports the common Markdown needed by the examples:

- headings with generated IDs
- paragraphs, links, images, and autolinks
- unordered lists
- blockquotes
- fenced code blocks with language classes
- simple pipe tables
- emphasis and strong emphasis

The renderer is intentionally isolated so it can be replaced by a full cmark-gfm integration later.

## Layouts

Layouts are HTML files in the configured `layouts_dir`.

Available tokens:

- `{{site.title}}`
- `{{site.url}}`
- `{{site.language}}`
- `{{site.author}}`
- `{{page.title}}`
- `{{page.description}}`
- `{{page.date}}`
- `{{page.updated}}`
- `{{page.tags}}`
- `{{page.categories}}`
- `{{page.series}}`
- `{{page.transition}}`
- `{{toc}}`
- `{{content}}`
- `{{post_list}}`
- `{{zlog.head}}`
- `{{zlog.runtime}}`

The generated HTML is validated during `check` and `build`.

## Static Assets

Files under `static/` are copied recursively into the output directory.

For local PNG and JPEG images referenced from static assets, zlog adds `width` and `height` attributes when they are missing.

## Deploy

Deploy the configured output directory, usually `public/`, to any static host.

```bash
./zig-out/bin/zlog check .
./zig-out/bin/zlog build .
```

Set `url` before publishing so RSS and sitemap output use absolute production URLs.

## Examples

- `examples/blog`
- `examples/docs`
- `examples/portfolio`

Each example can be checked and built with the local binary.
