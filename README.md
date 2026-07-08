# zlog

zlog is a Zig-native static site generator for small blogs and static sites. It
builds local Markdown content into static HTML, listing pages, taxonomy pages,
RSS, a sitemap, and copied static assets.

## Install

Build from source with Zig 0.16.0 and the cmark-gfm development libraries:

```bash
sudo apt-get install libcmark-gfm-dev libcmark-gfm-extensions-dev
zig build
```

The development binary is written to `zig-out/bin/zlog`.

Useful verification commands:

```bash
zig build test
zig build release-local
./zig-out/bin/zlog --help
```

Release archive naming is documented in `docs/releases.md`.

## Continuous Integration

Pull requests run the GitHub Actions workflow in `.github/workflows/ci.yml`. It
installs the cmark-gfm development packages, sets up Zig 0.16.0, then runs
formatting, tests, a build, and example-site check/build commands.

Most CI failures can be reproduced locally with:

```bash
zig fmt --check build.zig src/main.zig test/cli_integration.zig
zig build test
zig build
./zig-out/bin/zlog check examples/blog
./zig-out/bin/zlog build examples/blog
./zig-out/bin/zlog check examples/docs
./zig-out/bin/zlog build examples/docs
./zig-out/bin/zlog check examples/portfolio
./zig-out/bin/zlog build examples/portfolio
```

## Quickstart

```bash
zig build
./zig-out/bin/zlog init my-site
./zig-out/bin/zlog check my-site
./zig-out/bin/zlog build my-site
./zig-out/bin/zlog dev my-site 1111
```

`init` creates this starter structure:

```text
my-site/
  zlog.ziggy
  content/
    index.md
    posts/hello.md
  layouts/
    base.shtml
    post.shtml
```

`build` writes the generated site to `public/` by default. `dev` builds once,
serves that output on localhost, watches `zlog.ziggy`, `content/`, `layouts/`,
and `static/`, then reloads browser pages after successful rebuilds. If a
rebuild fails, the previous output stays served and the browser shows a failure
notice until the next successful save.

## Commands

```bash
zlog init [dir]
zlog check [dir]
zlog build [dir]
zlog dev [dir] [port]
```

- `init` scaffolds a starter site.
- `check` validates config, frontmatter, required post dates, duplicate heading
  IDs, internal links and anchors, generated HTML structure, and duplicate
  `view-transition-name` values.
- `build` writes static HTML, paginated listings, taxonomy pages, archive
  pages, RSS, sitemap, and static assets.
- `dev` runs `build`, serves the output directory, watches project files, and
  provides live reload over a local Server-Sent Events endpoint.

## Configuration

Configuration lives in `zlog.ziggy`.

```zig
.title = "example.dev",
.url = "https://example.dev",
.language = "en",
.timezone = "UTC",
.author = "Example Author",
.content_dir = "content",
.layouts_dir = "layouts",
.out_dir = "public",
.permalink = "/posts/:year/:month/:slug/",
.page_size = 10,
.prefetch_default = "hover",
.speculation_rules = true,
```

Important fields:

- `.url` is used for absolute RSS and sitemap URLs.
- `.language`, `.timezone`, and `.author` feed generated metadata, RSS, and
  templates.
- `.content_dir`, `.layouts_dir`, and `.out_dir` change the project folders.
- `.permalink` supports `:slug`, `:year`, `:month`, and `:day`.
- `.page_size` controls index, taxonomy, and archive pagination.
- `.prefetch_default` fills Markdown links that do not set
  `data-z-prefetch` themselves.
- `.speculation_rules` controls generated Speculation Rules in page heads.

## Frontmatter

Markdown files use Ziggy-style frontmatter.

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

Pages require `.title`. Posts also require `.date`. Draft content is skipped by
published routes, listing pages, taxonomy pages, RSS, and sitemap output.

The current `zlog dev` command rebuilds and serves the same production output
path on localhost, so it does not publish drafts locally.

## Markdown

Markdown is rendered with cmark-gfm and the core GitHub-flavored Markdown
features used by zlog:

- headings with generated IDs
- links, images, autolinks, lists, and blockquotes
- fenced code blocks with language classes
- pipe tables
- emphasis, strong emphasis, and strikethrough
- task lists and footnotes

zlog adds stable heading IDs and `data-z-prefetch` placeholders after Markdown
rendering.

## Layouts

Layouts are HTML files under the configured `layouts_dir`. They use explicit
`z-*` attributes instead of `{{...}}` tokens.

- `z-text="binding"` replaces an element body with escaped text.
- `z-html="binding"` replaces an element body with trusted rendered HTML.
- `z-replace="binding"` replaces the whole element with trusted rendered HTML.
- `z-attr:name="binding"` writes an escaped attribute when the binding is not
  empty.
- `z-replace="page.taxonomies"` inserts links for tags, categories, and series.
- `z-replace="pagination"` inserts generated pagination navigation when a
  listing spans multiple pages.

Supported bindings include `site.title`, `site.url`, `site.language`,
`site.timezone`, `site.author`, `page.title`, `page.full_title`, `page.date`,
`page.transition`, `page.tags`, `page.taxonomies`, `content`, `post_list`,
`pagination`, `pagination.current`, `pagination.total`,
`pagination.previous_url`, `pagination.next_url`, `zlog.head`, and
`zlog.runtime`.

The renderer validates layout structure and rejects legacy `{{...}}` tokens.
`zlog check` also validates rendered HTML and rejects duplicate
`view-transition-name` values within the same page.

## Generated Pages

`build` emits:

- content pages and posts
- the home listing and additional `/page/N/` pages when needed
- tag pages under `/tags/:slug/`
- category pages under `/categories/:slug/`
- series pages under `/series/:slug/`
- archive pages under `/archive/`
- `rss.xml`
- `sitemap.xml`

RSS and sitemap output use `.url` for absolute URLs. Sitemap entries exclude
drafts, RSS, sitemap, and static asset routes.

## Navigation

Generated pages include:

- `@view-transition { navigation: auto; }` CSS
- RouteGraph-derived `script type="speculationrules"` document rules for known
  internal `tap` and `hover` links
- a small JavaScript fallback for `hover`, `tap`, `viewport`, and `load`
  prefetch values

The dev server injects its live reload script only into served HTML responses.
It does not write live reload code into files generated by `zlog build`.

## Static Assets

Files under `static/` are copied recursively into the output directory. Static
assets can be linked from Markdown or layouts with root-relative URLs such as
`/app.css` or `/img/logo.png`.

For local PNG and JPEG assets referenced by generated pages, zlog adds missing
`width` and `height` attributes when dimensions can be read.

## Deploy

Before publishing, set `.url` to the production origin so RSS and sitemap URLs
are correct.

```bash
./zig-out/bin/zlog check .
./zig-out/bin/zlog build .
```

Deploy the configured output directory, usually `public/`, to any static host.

## Examples

The repository includes blog, docs, and portfolio examples:

```bash
./zig-out/bin/zlog check examples/blog
./zig-out/bin/zlog build examples/blog
./zig-out/bin/zlog check examples/docs
./zig-out/bin/zlog build examples/docs
./zig-out/bin/zlog check examples/portfolio
./zig-out/bin/zlog build examples/portfolio
```
