const std = @import("std");
var runtime_io: std.Io = undefined;

const SiteConfig = struct {
    title: []const u8 = "zlog site",
    url: []const u8 = "",
    language: []const u8 = "en",
    timezone: []const u8 = "UTC",
    author: []const u8 = "",
    content_dir: []const u8 = "content",
    layouts_dir: []const u8 = "layouts",
    out_dir: []const u8 = "public",
    permalink: []const u8 = "/:slug/",
    page_size: usize = 10,
    prefetch_default: []const u8 = "hover",
    speculation_rules: bool = true,
    live_reload: bool = true,
    search_index: bool = true,
    client_router: bool = false,
    plugin_hooks: bool = false,
};

const Frontmatter = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    date: []const u8 = "",
    updated: []const u8 = "",
    slug: []const u8 = "",
    layout: []const u8 = "base.shtml",
    tags: []const []const u8 = &.{},
    categories: []const []const u8 = &.{},
    series: []const u8 = "",
    draft: bool = false,
    prefetch: []const u8 = "",
    transition: []const u8 = "",
};

const Heading = struct {
    level: usize,
    id: []const u8,
    title: []const u8,
};

const Page = struct {
    source_path: []const u8,
    rel_path: []const u8,
    slug: []const u8,
    url: []const u8,
    fm: Frontmatter,
    markdown: []const u8,
    html: []const u8,
    toc: []const Heading,
    is_post: bool,
};

const RouteKind = enum { page, post, tag, archive, rss, sitemap, static_asset, search_index };

const Route = struct {
    kind: RouteKind,
    source_path: []const u8 = "",
    url: []const u8,
    out_path: []const u8,
};

const RouteGraph = struct {
    routes: std.array_list.Managed(Route),

    fn init(allocator: std.mem.Allocator) RouteGraph {
        return .{ .routes = std.array_list.Managed(Route).init(allocator) };
    }

    fn add(self: *RouteGraph, route: Route) !void {
        try self.routes.append(route);
    }

    fn containsUrl(self: RouteGraph, url: []const u8) bool {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.url, url)) return true;
        }
        return false;
    }
};

const AssetKind = enum { site, page, build };

const Asset = struct {
    kind: AssetKind,
    source_path: []const u8,
    out_path: []const u8,
    url: []const u8,
};

const AssetGraph = struct {
    assets: std.array_list.Managed(Asset),

    fn init(allocator: std.mem.Allocator) AssetGraph {
        return .{ .assets = std.array_list.Managed(Asset).init(allocator) };
    }

    fn add(self: *AssetGraph, asset: Asset) !void {
        try self.assets.append(asset);
    }

    fn containsUrl(self: AssetGraph, url: []const u8) bool {
        for (self.assets.items) |asset| {
            if (std.mem.eql(u8, asset.url, url)) return true;
        }
        return false;
    }
};

const BuildOptions = struct {
    mode: enum { production, development } = .production,
    inject_live_reload: bool = false,
};

const CliError = error{Usage};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    runtime_io = init.io;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printHelp();
        return;
    }

    const cmd = args[1];
    const dir = if (args.len >= 3) args[2] else ".";

    if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator, dir);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try cmdCheck(allocator, dir);
    } else if (std.mem.eql(u8, cmd, "build")) {
        try cmdBuild(allocator, dir, .{});
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try cmdDev(allocator, dir);
    } else {
        try stderr("unknown command: {s}\n\n", .{cmd});
        try printHelp();
        return CliError.Usage;
    }
}

fn printHelp() !void {
    try stdout(
        \\zlog - Zig-native blog SSG prototype
        \\
        \\Usage:
        \\  zlog init [dir]
        \\  zlog check [dir]
        \\  zlog build [dir]
        \\  zlog dev [dir]
        \\
    , .{});
}

fn stdout(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}

fn stderr(comptime fmt: []const u8, args: anytype) !void {
    std.debug.print(fmt, args);
}

fn cmdInit(allocator: std.mem.Allocator, dir: []const u8) !void {
    try makeDirPath(dir);
    try writeNew(allocator, dir, "zlog.ziggy", initConfig);
    try writeNew(allocator, dir, "content/index.md", initIndex);
    try writeNew(allocator, dir, "content/posts/hello.md", initPost);
    try writeNew(allocator, dir, "layouts/base.shtml", initBaseLayout);
    try writeNew(allocator, dir, "layouts/post.shtml", initPostLayout);
    try stdout("initialized zlog site at {s}\n", .{dir});
}

fn cmdCheck(allocator: std.mem.Allocator, dir: []const u8) !void {
    const site = try loadSite(allocator, dir);
    var pages = try loadPages(allocator, dir, site);
    defer pages.deinit();
    var assets = try buildAssetGraph(allocator, dir, site);
    defer assets.assets.deinit();
    var routes = try buildRouteGraph(allocator, dir, site, pages.items, assets);
    defer routes.routes.deinit();
    try validatePages(allocator, pages.items, routes, assets);
    try validateHtmlPages(allocator, pages.items);
    try stdout("check ok: {d} pages\n", .{pages.items.len});
}

fn cmdBuild(allocator: std.mem.Allocator, dir: []const u8, options: BuildOptions) !void {
    const site = try loadSite(allocator, dir);
    var pages = try loadPages(allocator, dir, site);
    defer pages.deinit();
    var assets = try buildAssetGraph(allocator, dir, site);
    defer assets.assets.deinit();
    var routes = try buildRouteGraph(allocator, dir, site, pages.items, assets);
    defer routes.routes.deinit();
    try validatePages(allocator, pages.items, routes, assets);
    try validateHtmlPages(allocator, pages.items);

    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try cleanAndCreate(out_dir);
    try copyAssets(allocator, assets);

    const post_list = try renderPostList(allocator, pages.items, site);
    const head = renderHead(site);
    const runtime = try renderRuntime(allocator, site, options);

    for (pages.items) |page| {
        if (options.mode == .production and page.fm.draft) continue;
        const layout_name = if (page.fm.layout.len == 0) "base.shtml" else page.fm.layout;
        const layout_path = try join(allocator, &.{ dir, site.layouts_dir, layout_name });
        const layout = std.Io.Dir.cwd().readFileAlloc(runtime_io, layout_path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => if (page.is_post) initPostLayout else initBaseLayout,
            else => return err,
        };
        const rendered = try renderLayout(allocator, layout, site, page, page.html, post_list, head, runtime);
        const final_html = try rewriteNavigationAttributes(allocator, rendered, site.prefetch_default);
        const final_with_images = try addImageDimensions(allocator, final_html, dir);
        try validateHtml(allocator, final_with_images, page.source_path);
        const rel = outputRelForUrl(allocator, page.url) catch return error.InvalidSite;
        const out_path = try join(allocator, &.{ out_dir, rel });
        try writeAll(allocator, out_path, final_with_images);
    }

    try renderTagPages(allocator, out_dir, pages.items, site, head, runtime, options);
    try renderCategoryPages(allocator, out_dir, pages.items, site, head, runtime, options);
    try renderArchivePage(allocator, out_dir, pages.items, site, head, runtime, options);
    try renderIndexPagination(allocator, out_dir, pages.items, site, head, runtime, options);
    try writeAll(allocator, try join(allocator, &.{ out_dir, "rss.xml" }), try renderRss(allocator, pages.items, site));
    try writeAll(allocator, try join(allocator, &.{ out_dir, "sitemap.xml" }), try renderSitemap(allocator, pages.items, site));
    if (site.search_index) try writeAll(allocator, try join(allocator, &.{ out_dir, "search.json" }), try renderSearchIndex(allocator, pages.items, site));
    try stdout("built {d} pages into {s}\n", .{ countPublishedPages(pages.items, options), out_dir });
}

fn cmdDev(allocator: std.mem.Allocator, dir: []const u8) !void {
    try cmdBuild(allocator, dir, .{ .mode = .development });
    var previous = try siteFingerprint(allocator, dir);
    try stdout("watching {s}; press Ctrl-C to stop\n", .{dir});
    while (true) {
        try std.Io.sleep(runtime_io, std.Io.Duration.fromMilliseconds(750), .awake);
        const current = try siteFingerprint(allocator, dir);
        if (current != previous) {
            previous = current;
            cmdBuild(allocator, dir, .{ .mode = .development }) catch |err| {
                try stderr("rebuild failed: {s}\n", .{@errorName(err)});
            };
        }
    }
}

fn loadSite(allocator: std.mem.Allocator, dir: []const u8) !SiteConfig {
    const path = try join(allocator, &.{ dir, "zlog.ziggy" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return SiteConfig{},
        else => return err,
    };
    return SiteConfig{
        .title = parseStringField(text, "title") orelse "zlog site",
        .url = trimTrailingSlash(parseStringField(text, "url") orelse ""),
        .language = parseStringField(text, "language") orelse "en",
        .timezone = parseStringField(text, "timezone") orelse "UTC",
        .author = parseStringField(text, "author") orelse "",
        .content_dir = parseStringField(text, "content_dir") orelse "content",
        .layouts_dir = parseStringField(text, "layouts_dir") orelse "layouts",
        .out_dir = parseStringField(text, "out_dir") orelse "public",
        .permalink = parseStringField(text, "permalink") orelse "/:slug/",
        .page_size = parseUsizeField(text, "page_size") orelse 10,
        .prefetch_default = parseStringField(text, "prefetch_default") orelse "hover",
        .speculation_rules = parseBoolField(text, "speculation_rules") orelse true,
        .live_reload = parseBoolField(text, "live_reload") orelse true,
        .search_index = parseBoolField(text, "search_index") orelse true,
        .client_router = parseBoolField(text, "client_router") orelse false,
        .plugin_hooks = parseBoolField(text, "plugin_hooks") orelse false,
    };
}

fn loadPages(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig) !std.array_list.Managed(Page) {
    var pages = std.array_list.Managed(Page).init(allocator);
    const content_root = try join(allocator, &.{ dir, site.content_dir });
    try walkMarkdown(allocator, content_root, content_root, site, &pages);
    std.mem.sort(Page, pages.items, {}, pageLessThan);
    return pages;
}

fn pageLessThan(_: void, a: Page, b: Page) bool {
    if (a.is_post != b.is_post) return !a.is_post;
    return std.mem.order(u8, b.fm.date, a.fm.date) == .lt;
}

fn walkMarkdown(allocator: std.mem.Allocator, root: []const u8, dir: []const u8, site: SiteConfig, pages: *std.array_list.Managed(Page)) !void {
    var d = std.Io.Dir.cwd().openDir(runtime_io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        const child = try join(allocator, &.{ dir, entry.name });
        switch (entry.kind) {
            .directory => try walkMarkdown(allocator, root, child, site, pages),
            .file => if (std.mem.endsWith(u8, entry.name, ".md")) {
                try pages.append(try loadPage(allocator, root, child, site));
            },
            else => {},
        }
    }
}

fn loadPage(allocator: std.mem.Allocator, content_root: []const u8, path: []const u8, site: SiteConfig) !Page {
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(8 * 1024 * 1024));
    const split = splitFrontmatter(text);
    const fm = try parseFrontmatter(allocator, split.frontmatter);
    const rel = try allocator.dupe(u8, std.mem.trimStart(u8, path[content_root.len..], std.Io.Dir.path.sep_str));
    const is_post = std.mem.startsWith(u8, rel, "posts/");
    const path_slug = slugFromPath(rel);
    const slug = if (fm.slug.len > 0) fm.slug else path_slug;
    const url = if (std.mem.eql(u8, rel, "index.md")) try allocator.dupe(u8, "/") else try permalinkForPage(allocator, site, fm, slug, is_post);
    var headings = std.array_list.Managed(Heading).init(allocator);
    const html = try markdownToHtml(allocator, split.body, &headings);
    return Page{ .source_path = path, .rel_path = rel, .slug = slug, .url = url, .fm = fm, .markdown = split.body, .html = html, .toc = try headings.toOwnedSlice(), .is_post = is_post };
}

const FrontmatterSplit = struct { frontmatter: []const u8, body: []const u8 };

fn splitFrontmatter(text: []const u8) FrontmatterSplit {
    if (!std.mem.startsWith(u8, text, "---")) return .{ .frontmatter = "", .body = text };
    const rest = text[3..];
    if (std.mem.indexOf(u8, rest, "\n---")) |idx| {
        const body_start = 3 + idx + 4;
        return .{ .frontmatter = std.mem.trim(u8, rest[0..idx], " \t\r\n"), .body = std.mem.trimStart(u8, text[body_start..], "\r\n") };
    }
    return .{ .frontmatter = "", .body = text };
}

fn parseFrontmatter(allocator: std.mem.Allocator, text: []const u8) !Frontmatter {
    return Frontmatter{
        .title = parseStringField(text, "title") orelse "",
        .description = parseStringField(text, "description") orelse "",
        .date = parseStringField(text, "date") orelse "",
        .updated = parseStringField(text, "updated") orelse "",
        .slug = parseStringField(text, "slug") orelse "",
        .layout = parseStringField(text, "layout") orelse "base.shtml",
        .tags = try parseStringArrayField(allocator, text, "tags"),
        .categories = try parseStringArrayField(allocator, text, "categories"),
        .series = parseStringField(text, "series") orelse "",
        .draft = parseBoolField(text, "draft") orelse false,
        .prefetch = parseStringField(text, "prefetch") orelse "",
        .transition = parseStringField(text, "transition") orelse "",
    };
}

fn parseStringField(text: []const u8, name: []const u8) ?[]const u8 {
    const key = std.fmt.allocPrint(std.heap.page_allocator, ".{s}", .{name}) catch return null;
    defer std.heap.page_allocator.free(key);
    if (std.mem.indexOf(u8, text, key)) |start| {
        const after_key = text[start + key.len ..];
        const eq = std.mem.indexOfScalar(u8, after_key, '=') orelse return null;
        const after_eq = std.mem.trimStart(u8, after_key[eq + 1 ..], " \t");
        if (after_eq.len == 0 or after_eq[0] != '"') return null;
        const rest = after_eq[1..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }
    const yaml_key = std.fmt.allocPrint(std.heap.page_allocator, "{s}:", .{name}) catch return null;
    defer std.heap.page_allocator.free(yaml_key);
    if (std.mem.indexOf(u8, text, yaml_key)) |start| {
        const after_key = text[start + yaml_key.len ..];
        const line_end = std.mem.indexOfScalar(u8, after_key, '\n') orelse after_key.len;
        const value = std.mem.trim(u8, after_key[0..line_end], " \t\r\"");
        if (value.len > 0 and value[0] != '[') return value;
    }
    return null;
}

fn parseUsizeField(text: []const u8, name: []const u8) ?usize {
    const key = std.fmt.allocPrint(std.heap.page_allocator, ".{s}", .{name}) catch return null;
    defer std.heap.page_allocator.free(key);
    if (std.mem.indexOf(u8, text, key)) |start| {
        const after_key = text[start + key.len ..];
        const eq = std.mem.indexOfScalar(u8, after_key, '=') orelse return null;
        const value = std.mem.trimStart(u8, after_key[eq + 1 ..], " \t");
        var end: usize = 0;
        while (end < value.len and std.ascii.isDigit(value[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(usize, value[0..end], 10) catch null;
    }
    return null;
}

fn parseBoolField(text: []const u8, name: []const u8) ?bool {
    const key = std.fmt.allocPrint(std.heap.page_allocator, ".{s}", .{name}) catch return null;
    defer std.heap.page_allocator.free(key);
    if (std.mem.indexOf(u8, text, key)) |start| {
        const after_key = text[start + key.len ..];
        const eq = std.mem.indexOfScalar(u8, after_key, '=') orelse return null;
        const value = std.mem.trimStart(u8, after_key[eq + 1 ..], " \t");
        if (std.mem.startsWith(u8, value, "true")) return true;
        if (std.mem.startsWith(u8, value, "false")) return false;
    }
    const yaml_key = std.fmt.allocPrint(std.heap.page_allocator, "{s}:", .{name}) catch return null;
    defer std.heap.page_allocator.free(yaml_key);
    if (std.mem.indexOf(u8, text, yaml_key)) |start| {
        const after_key = text[start + yaml_key.len ..];
        const value = std.mem.trimStart(u8, after_key, " \t");
        if (std.mem.startsWith(u8, value, "true")) return true;
        if (std.mem.startsWith(u8, value, "false")) return false;
    }
    return null;
}

fn parseStringArrayField(allocator: std.mem.Allocator, text: []const u8, name: []const u8) ![]const []const u8 {
    const key = try std.fmt.allocPrint(allocator, ".{s}", .{name});
    defer allocator.free(key);
    if (std.mem.indexOf(u8, text, key)) |start| {
        const after_key = text[start + key.len ..];
        const eq = std.mem.indexOfScalar(u8, after_key, '=') orelse return &.{};
        const after_eq = std.mem.trimStart(u8, after_key[eq + 1 ..], " \t");
        if (after_eq.len == 0 or after_eq[0] != '[') return &.{};
        const close = std.mem.indexOfScalar(u8, after_eq, ']') orelse return &.{};
        var result = std.array_list.Managed([]const u8).init(allocator);
        var rest = after_eq[1..close];
        while (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
            rest = rest[q1 + 1 ..];
            const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            try result.append(rest[0..q2]);
            rest = rest[q2 + 1 ..];
        }
        return result.toOwnedSlice();
    }
    const yaml_key = try std.fmt.allocPrint(allocator, "{s}:", .{name});
    defer allocator.free(yaml_key);
    if (std.mem.indexOf(u8, text, yaml_key)) |start| {
        const after_key = text[start + yaml_key.len ..];
        const line_end = std.mem.indexOfScalar(u8, after_key, '\n') orelse after_key.len;
        const line = std.mem.trim(u8, after_key[0..line_end], " \t\r");
        if (line.len > 0 and line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return &.{};
            var result = std.array_list.Managed([]const u8).init(allocator);
            var rest = line[1..close];
            while (std.mem.indexOfScalar(u8, rest, '"')) |q1| {
                rest = rest[q1 + 1 ..];
                const q2 = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                try result.append(rest[0..q2]);
                rest = rest[q2 + 1 ..];
            }
            return result.toOwnedSlice();
        }
    }
    return &.{};
}

fn markdownToHtml(allocator: std.mem.Allocator, markdown: []const u8, headings: *std.array_list.Managed(Heading)) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var in_list = false;
    var in_blockquote = false;
    var in_code = false;
    var code_lang: []const u8 = "";
    var pending_table_header: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "```")) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            if (pending_table_header) |header| {
                try out.appendSlice("<p>");
                try renderInlineMarkdown(allocator, &out, header);
                try out.appendSlice("</p>\n");
                pending_table_header = null;
            }
            if (in_code) {
                try out.appendSlice("</code></pre>\n");
                in_code = false;
                code_lang = "";
            } else {
                code_lang = std.mem.trim(u8, line[3..], " \t");
                if (code_lang.len > 0) {
                    const class_name = try safeCssIdent(allocator, code_lang);
                    defer allocator.free(class_name);
                    try out.print("<pre><code class=\"language-{s}\">", .{class_name});
                } else {
                    try out.appendSlice("<pre><code>");
                }
                in_code = true;
            }
            continue;
        }
        if (in_code) {
            try appendEscaped(&out, line);
            try out.append('\n');
            continue;
        }
        if (std.mem.startsWith(u8, line, ":::")) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            const kind = std.mem.trim(u8, line[3..], " \t");
            const class_name = try safeCssIdent(allocator, if (kind.len > 0) kind else "note");
            defer allocator.free(class_name);
            try out.print("<aside class=\"zlog-callout zlog-callout-{s}\">\n", .{class_name});
            if (kind.len > 0) {
                try out.appendSlice("<p class=\"zlog-callout-title\">");
                try appendEscaped(&out, kind);
                try out.appendSlice("</p>\n");
            }
            while (lines.next()) |callout_raw| {
                const callout_line = std.mem.trimEnd(u8, callout_raw, "\r");
                if (std.mem.startsWith(u8, callout_line, ":::")) break;
                if (std.mem.trim(u8, callout_line, " \t").len == 0) continue;
                try out.appendSlice("<p>");
                try renderInlineMarkdown(allocator, &out, callout_line);
                try out.appendSlice("</p>\n");
            }
            try out.appendSlice("</aside>\n");
            continue;
        }
        if (pending_table_header) |header| {
            if (isMarkdownTableDivider(line)) {
                if (in_list) {
                    try out.appendSlice("</ul>\n");
                    in_list = false;
                }
                try renderTable(allocator, &out, header, &lines);
                pending_table_header = null;
                continue;
            } else {
                try out.appendSlice("<p>");
                try renderInlineMarkdown(allocator, &out, header);
                try out.appendSlice("</p>\n");
                pending_table_header = null;
            }
        }
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "#")) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            if (level > 6) level = 6;
            const title = std.mem.trimStart(u8, line[level..], " ");
            const id = try slugify(allocator, title);
            try headings.append(.{ .level = level, .id = id, .title = title });
            try out.print("<h{d} id=\"{s}\">", .{ level, id });
            try appendEscaped(&out, title);
            try out.print("</h{d}>\n", .{level});
        } else if (std.mem.startsWith(u8, line, ">")) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (!in_blockquote) {
                try out.appendSlice("<blockquote>\n");
                in_blockquote = true;
            }
            try out.appendSlice("<p>");
            try renderInlineMarkdown(allocator, &out, std.mem.trim(u8, line[1..], " \t"));
            try out.appendSlice("</p>\n");
        } else if (std.mem.startsWith(u8, line, "- ")) {
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            if (!in_list) {
                try out.appendSlice("<ul>\n");
                in_list = true;
            }
            try out.appendSlice("<li>");
            try renderInlineMarkdown(allocator, &out, line[2..]);
            try out.appendSlice("</li>\n");
        } else {
            if (std.mem.indexOfScalar(u8, line, '|') != null) {
                pending_table_header = line;
                continue;
            }
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            if (in_blockquote) {
                try out.appendSlice("</blockquote>\n");
                in_blockquote = false;
            }
            try out.appendSlice("<p>");
            try renderInlineMarkdown(allocator, &out, line);
            try out.appendSlice("</p>\n");
        }
    }
    if (pending_table_header) |header| {
        try out.appendSlice("<p>");
        try renderInlineMarkdown(allocator, &out, header);
        try out.appendSlice("</p>\n");
    }
    if (in_code) try out.appendSlice("</code></pre>\n");
    if (in_list) try out.appendSlice("</ul>\n");
    if (in_blockquote) try out.appendSlice("</blockquote>\n");
    return out.toOwnedSlice();
}

fn renderInlineMarkdown(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '!' and text[i + 1] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 2, ']')) |close_alt| {
                if (close_alt + 1 < text.len and text[close_alt + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_alt + 2, ')')) |close_url| {
                        const alt = text[i + 2 .. close_alt];
                        const url = text[close_alt + 2 .. close_url];
                        try out.appendSlice("<img src=\"");
                        try appendEscaped(out, url);
                        try out.appendSlice("\" alt=\"");
                        try appendEscaped(out, alt);
                        try out.appendSlice("\">");
                        i = close_url + 1;
                        continue;
                    }
                }
            }
        } else if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i, ']')) |close_label| {
                if (close_label + 1 < text.len and text[close_label + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_label + 2, ')')) |close_url| {
                        const label = text[i + 1 .. close_label];
                        const url = text[close_label + 2 .. close_url];
                        try out.appendSlice("<a href=\"");
                        try appendEscaped(out, url);
                        try out.appendSlice("\" data-z-prefetch>");
                        try renderInlineMarkdown(allocator, out, label);
                        try out.appendSlice("</a>");
                        i = close_url + 1;
                        continue;
                    }
                }
            }
        } else if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                try out.appendSlice("<strong>");
                try appendEscaped(out, text[i + 2 .. end]);
                try out.appendSlice("</strong>");
                i = end + 2;
                continue;
            }
        } else if (text[i] == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                try out.appendSlice("<em>");
                try appendEscaped(out, text[i + 1 .. end]);
                try out.appendSlice("</em>");
                i = end + 1;
                continue;
            }
        } else if (std.mem.startsWith(u8, text[i..], "http://") or std.mem.startsWith(u8, text[i..], "https://")) {
            var end = i;
            while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
            const url = std.mem.trim(u8, text[i..end], ".,)");
            try out.appendSlice("<a href=\"");
            try appendEscaped(out, url);
            try out.appendSlice("\">");
            try appendEscaped(out, url);
            try out.appendSlice("</a>");
            i += url.len;
            continue;
        }
        try appendEscapedChar(out, text[i]);
        i += 1;
    }
}

fn isMarkdownTableDivider(line: []const u8) bool {
    if (std.mem.indexOfScalar(u8, line, '|') == null) return false;
    var saw_dash = false;
    for (line) |c| switch (c) {
        ' ', '\t', '|', ':', '-' => {
            if (c == '-') saw_dash = true;
        },
        else => return false,
    };
    return saw_dash;
}

fn renderTable(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), header: []const u8, lines: *std.mem.SplitIterator(u8, .scalar)) !void {
    try out.appendSlice("<table>\n<thead><tr>");
    try renderTableRow(allocator, out, header, "th");
    try out.appendSlice("</tr></thead>\n<tbody>\n");
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0 or std.mem.indexOfScalar(u8, line, '|') == null) break;
        try out.appendSlice("<tr>");
        try renderTableRow(allocator, out, line, "td");
        try out.appendSlice("</tr>\n");
    }
    try out.appendSlice("</tbody>\n</table>\n");
}

fn renderTableRow(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), line: []const u8, comptime cell: []const u8) !void {
    var row = std.mem.trim(u8, line, " \t|");
    while (true) {
        const next = std.mem.indexOfScalar(u8, row, '|');
        const value = if (next) |idx| row[0..idx] else row;
        try out.print("<{s}>", .{cell});
        try renderInlineMarkdown(allocator, out, std.mem.trim(u8, value, " \t"));
        try out.print("</{s}>", .{cell});
        if (next) |idx| {
            row = row[idx + 1 ..];
        } else {
            break;
        }
    }
}

fn validatePages(allocator: std.mem.Allocator, pages: []Page, routes: RouteGraph, assets: AssetGraph) !void {
    for (pages) |page| {
        try validateContentSchema(page);
        try validateDuplicateHeadings(allocator, page);
        try validateInternalLinks(allocator, page, pages, routes, assets);
        try validateDuplicateTransitionNames(allocator, page);
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    try stderr("error: " ++ fmt ++ "\n", args);
    return error.InvalidSite;
}

fn failAt(path: []const u8, line: usize, column: usize, comptime fmt: []const u8, args: anytype) !void {
    try stderr("{s}:{d}:{d}: error: " ++ fmt ++ "\n", .{ path, line, column } ++ args);
    return error.InvalidSite;
}

fn validateContentSchema(page: Page) !void {
    if (page.fm.title.len == 0) return failAt(page.source_path, frontmatterFieldLine(page.markdown, "title") orelse 1, 1, "missing required field .title", .{});
    if (page.is_post and page.fm.date.len == 0) return failAt(page.source_path, frontmatterFieldLine(page.markdown, "date") orelse 1, 1, "missing required field .date for posts", .{});
    if (page.fm.prefetch.len > 0 and !isPrefetchMode(page.fm.prefetch)) return fail("invalid .prefetch value '{s}' in {s}; expected hover, tap, viewport, load, or false", .{ page.fm.prefetch, page.source_path });
}

fn validateDuplicateHeadings(allocator: std.mem.Allocator, page: Page) !void {
    var ids = std.StringHashMap(void).init(allocator);
    for (page.toc) |heading| {
        if (ids.contains(heading.id)) return fail("duplicate heading id '{s}' in {s}", .{ heading.id, page.source_path });
        try ids.put(heading.id, {});
    }
}

fn validateInternalLinks(allocator: std.mem.Allocator, page: Page, pages: []Page, routes: RouteGraph, assets: AssetGraph) !void {
    var rest = page.markdown;
    while (std.mem.indexOf(u8, rest, "](")) |idx| {
        rest = rest[idx + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const url = rest[0..end];
        if (isExternalUrl(url) or std.mem.startsWith(u8, url, "mailto:") or std.mem.startsWith(u8, url, "tel:")) {
            rest = rest[end + 1 ..];
            continue;
        }
        const resolved = try resolveLinkUrl(allocator, page.url, url);
        if (!isKnownInternalTarget(resolved, page, pages, routes, assets)) return fail("broken internal link '{s}' in {s}", .{ url, page.source_path });
        rest = rest[end + 1 ..];
    }
}

fn renderLayout(allocator: std.mem.Allocator, layout: []const u8, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8) ![]const u8 {
    var out = try replaceAll(allocator, layout, "{{site.title}}", site.title);
    out = try replaceAll(allocator, out, "{{site.url}}", site.url);
    out = try replaceAll(allocator, out, "{{site.language}}", site.language);
    out = try replaceAll(allocator, out, "{{site.author}}", site.author);
    out = try replaceAll(allocator, out, "{{page.title}}", page.fm.title);
    out = try replaceAll(allocator, out, "{{page.description}}", page.fm.description);
    out = try replaceAll(allocator, out, "{{page.date}}", page.fm.date);
    out = try replaceAll(allocator, out, "{{page.updated}}", if (page.fm.updated.len > 0) page.fm.updated else page.fm.date);
    out = try replaceAll(allocator, out, "{{page.transition}}", page.fm.transition);
    out = try replaceAll(allocator, out, "{{page.tags}}", try renderTagsInline(allocator, page.fm.tags));
    out = try replaceAll(allocator, out, "{{page.categories}}", try renderTaxonomyInline(allocator, "categories", page.fm.categories));
    out = try replaceAll(allocator, out, "{{page.series}}", page.fm.series);
    out = try replaceAll(allocator, out, "{{toc}}", try renderToc(allocator, page.toc));
    out = try replaceAll(allocator, out, "{{content}}", content);
    out = try replaceAll(allocator, out, "{{post_list}}", post_list);
    out = try replaceAll(allocator, out, "{{zlog.head}}", head);
    out = try replaceAll(allocator, out, "{{zlog.runtime}}", runtime);
    out = try applyTransitionNames(allocator, out);
    return out;
}

fn renderPostList(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<section class=\"zlog-posts\">\n<h2>Posts</h2>\n<ul>\n");
    var rendered: usize = 0;
    for (pages) |p| if (p.is_post and !p.fm.draft) {
        if (rendered >= site.page_size) continue;
        rendered += 1;
        const prefetch = if (p.fm.prefetch.len > 0) p.fm.prefetch else site.prefetch_default;
        try out.print("<li><a href=\"{s}\" data-z-prefetch=\"{s}\"><span style=\"view-transition-name:{s}\">", .{ p.url, prefetch, try safeCssIdent(allocator, if (p.fm.transition.len > 0) p.fm.transition else p.slug) });
        try appendEscaped(&out, p.fm.title);
        try out.print("</span></a> <time>{s}</time></li>\n", .{p.fm.date});
    };
    try out.appendSlice("</ul>\n</section>\n");
    return out.toOwnedSlice();
}

fn renderTagsInline(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    return renderTaxonomyInline(allocator, "tags", tags);
}

fn renderTaxonomyInline(allocator: std.mem.Allocator, base: []const u8, values: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (values, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(" ");
        try out.print("<a href=\"/{s}/{s}/\" data-z-prefetch=\"hover\">#", .{ base, try slugify(allocator, tag) });
        try appendEscaped(&out, tag);
        try out.appendSlice("</a>");
    }
    return out.toOwnedSlice();
}

fn renderToc(allocator: std.mem.Allocator, headings: []const Heading) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    if (headings.len == 0) return out.toOwnedSlice();
    try out.appendSlice("<nav class=\"zlog-toc\" aria-label=\"Table of contents\"><ol>\n");
    for (headings) |heading| {
        try out.print("<li data-level=\"{d}\"><a href=\"#{s}\">", .{ heading.level, heading.id });
        try appendEscaped(&out, heading.title);
        try out.appendSlice("</a></li>\n");
    }
    try out.appendSlice("</ol></nav>\n");
    return out.toOwnedSlice();
}

fn renderHead(site: SiteConfig) []const u8 {
    if (!site.speculation_rules) return
    \\<style>
    \\@view-transition { navigation: auto; }
    \\@media (prefers-reduced-motion: reduce) { ::view-transition-group(*) { animation-duration: 0.01ms; } }
    \\body { max-width: 72ch; margin: 3rem auto; padding: 0 1rem; font: 16px/1.6 system-ui, sans-serif; }
    \\img { max-width: 100%; height: auto; }
    \\</style>
    ;
    return
    \\<style>
    \\@view-transition { navigation: auto; }
    \\@media (prefers-reduced-motion: reduce) { ::view-transition-group(*) { animation-duration: 0.01ms; } }
    \\body { max-width: 72ch; margin: 3rem auto; padding: 0 1rem; font: 16px/1.6 system-ui, sans-serif; }
    \\img { max-width: 100%; height: auto; }
    \\</style>
    \\<script type="speculationrules">{"prefetch":[{"where":{"selector_matches":"[data-z-prefetch='tap']"},"eagerness":"conservative"},{"where":{"selector_matches":"[data-z-prefetch='hover']"},"eagerness":"moderate"}]}</script>
    ;
}

fn renderRuntime(allocator: std.mem.Allocator, site: SiteConfig, options: BuildOptions) ![]const u8 {
    _ = allocator;
    _ = site;
    _ = options;
    return prefetchRuntime;
}

const prefetchRuntime =
    \\<script>
    \\(()=>{const seen=new Set();function ok(a){try{const u=new URL(a.href,location.href);return u.origin===location.origin&&!a.download&&!a.target&&!/[?&](logout|admin|search)=/.test(u.search)&&!seen.has(u.href)}catch{return false}}function pf(a){if(!ok(a))return;seen.add(a.href);const l=document.createElement('link');l.rel='prefetch';l.href=a.href;document.head.appendChild(l)}document.querySelectorAll('a[data-z-prefetch]').forEach(a=>{const m=a.dataset.zPrefetch||'hover';if(m==='false')return;if(m==='load')addEventListener('load',()=>pf(a),{once:true});else if(m==='tap')a.addEventListener('pointerdown',()=>pf(a),{once:true});else if(m==='viewport'&&'IntersectionObserver'in window){const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){pf(a);io.unobserve(a)}}));io.observe(a)}else{a.addEventListener('pointerenter',()=>pf(a),{once:true});a.addEventListener('focus',()=>pf(a),{once:true})}})})();
    \\</script>
;

fn rewriteNavigationAttributes(allocator: std.mem.Allocator, html: []const u8, default_prefetch: []const u8) ![]const u8 {
    return try replaceAll(allocator, html, "data-z-prefetch>", try std.fmt.allocPrint(allocator, "data-z-prefetch=\"{s}\">", .{default_prefetch}));
}

fn applyTransitionNames(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var rest = html;
    while (std.mem.indexOf(u8, rest, " z-transition-name=\"")) |idx| {
        try out.appendSlice(rest[0..idx]);
        rest = rest[idx + " z-transition-name=\"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const name = try safeCssIdent(allocator, rest[0..end]);
        try out.print(" style=\"view-transition-name:{s}\"", .{name});
        rest = rest[end + 1 ..];
    }
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

fn renderTagPages(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8, options: BuildOptions) !void {
    var seen = std.StringHashMap(void).init(allocator);
    for (pages) |p| if (p.is_post and !(options.mode == .production and p.fm.draft)) for (p.fm.tags) |tag| {
        const tag_slug = try slugify(allocator, tag);
        if (seen.contains(tag_slug)) continue;
        try seen.put(tag_slug, {});
        var body = std.array_list.Managed(u8).init(allocator);
        try body.print("<h1>#{s}</h1>\n<ul>\n", .{tag});
        for (pages) |q| if (q.is_post and !(options.mode == .production and q.fm.draft) and hasTag(q, tag)) {
            try body.print("<li><a href=\"{s}\" data-z-prefetch=\"hover\">", .{q.url});
            try appendEscaped(&body, q.fm.title);
            try body.appendSlice("</a></li>\n");
        };
        try body.appendSlice("</ul>");
        const fake = emptyPage(tag_slug, try std.fmt.allocPrint(allocator, "/tags/{s}/", .{tag_slug}), tag);
        const layout = initBaseLayout;
        const rendered = try renderLayout(allocator, layout, site, fake, try body.toOwnedSlice(), "", head, runtime);
        try writeAll(allocator, try join(allocator, &.{ out_dir, "tags", tag_slug, "index.html" }), rendered);
    };
}

fn renderCategoryPages(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8, options: BuildOptions) !void {
    var seen = std.StringHashMap(void).init(allocator);
    for (pages) |p| if (p.is_post and !(options.mode == .production and p.fm.draft)) for (p.fm.categories) |category| {
        const category_slug = try slugify(allocator, category);
        if (seen.contains(category_slug)) continue;
        try seen.put(category_slug, {});
        var body = std.array_list.Managed(u8).init(allocator);
        try body.print("<h1>{s}</h1>\n<ul>\n", .{category});
        var rendered: usize = 0;
        for (pages) |q| if (q.is_post and !(options.mode == .production and q.fm.draft) and hasCategory(q, category)) {
            if (rendered >= site.page_size) continue;
            rendered += 1;
            try body.print("<li><a href=\"{s}\" data-z-prefetch=\"hover\">", .{q.url});
            try appendEscaped(&body, q.fm.title);
            try body.appendSlice("</a></li>\n");
        };
        try body.appendSlice("</ul>");
        const fake = emptyPage(category_slug, try std.fmt.allocPrint(allocator, "/categories/{s}/", .{category_slug}), category);
        const rendered_html = try renderLayout(allocator, initBaseLayout, site, fake, try body.toOwnedSlice(), "", head, runtime);
        try writeAll(allocator, try join(allocator, &.{ out_dir, "categories", category_slug, "index.html" }), rendered_html);
    };
}

fn renderArchivePage(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8, options: BuildOptions) !void {
    var body = std.array_list.Managed(u8).init(allocator);
    try body.appendSlice("<h1>Archive</h1>\n<ul>\n");
    var archive_count: usize = 0;
    for (pages) |p| if (p.is_post and !(options.mode == .production and p.fm.draft)) {
        if (archive_count >= site.page_size) continue;
        archive_count += 1;
        try body.print("<li><time>{s}</time> <a href=\"{s}\" data-z-prefetch=\"hover\">", .{ p.fm.date, p.url });
        try appendEscaped(&body, p.fm.title);
        try body.appendSlice("</a></li>\n");
    };
    try body.appendSlice("</ul>");
    const fake = emptyPage("archive", "/archive/", "Archive");
    const rendered = try renderLayout(allocator, initBaseLayout, site, fake, try body.toOwnedSlice(), "", head, runtime);
    try writeAll(allocator, try join(allocator, &.{ out_dir, "archive", "index.html" }), rendered);
}

fn renderIndexPagination(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8, options: BuildOptions) !void {
    const total = countPosts(pages, options);
    if (site.page_size == 0 or total <= site.page_size) return;
    var page_no: usize = 2;
    var start = site.page_size;
    while (start < total) : ({
        start += site.page_size;
        page_no += 1;
    }) {
        var body = std.array_list.Managed(u8).init(allocator);
        try body.print("<h1>Posts, page {d}</h1>\n<ul>\n", .{page_no});
        var seen: usize = 0;
        var emitted: usize = 0;
        for (pages) |p| if (p.is_post and !(options.mode == .production and p.fm.draft)) {
            if (seen < start) {
                seen += 1;
                continue;
            }
            if (emitted >= site.page_size) break;
            emitted += 1;
            try body.print("<li><a href=\"{s}\" data-z-prefetch=\"hover\">", .{p.url});
            try appendEscaped(&body, p.fm.title);
            try body.appendSlice("</a></li>\n");
        };
        try body.appendSlice("</ul>\n<nav class=\"zlog-pagination\">");
        if (page_no > 2) try body.print("<a href=\"/page/{d}/\" data-z-prefetch=\"hover\">Previous</a> ", .{page_no - 1}) else try body.appendSlice("<a href=\"/\" data-z-prefetch=\"hover\">Previous</a> ");
        if (start + site.page_size < total) try body.print("<a href=\"/page/{d}/\" data-z-prefetch=\"hover\">Next</a>", .{page_no + 1});
        try body.appendSlice("</nav>");
        const url = try std.fmt.allocPrint(allocator, "/page/{d}/", .{page_no});
        const fake = emptyPage("page", url, "Posts");
        const html = try renderLayout(allocator, initBaseLayout, site, fake, try body.toOwnedSlice(), "", head, runtime);
        try writeAll(allocator, try join(allocator, &.{ out_dir, "page", try std.fmt.allocPrint(allocator, "{d}", .{page_no}), "index.html" }), html);
    }
}

fn renderRss(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"2.0\"><channel><title>");
    try appendEscaped(&out, site.title);
    try out.appendSlice("</title>");
    if (site.url.len > 0) try out.print("<link>{s}</link>", .{site.url});
    for (pages) |p| if (p.is_post and !p.fm.draft) {
        const abs = try absoluteUrl(allocator, site, p.url);
        try out.appendSlice("<item><title>");
        try appendEscaped(&out, p.fm.title);
        try out.appendSlice("</title>");
        try out.print("<link>{s}</link><guid>{s}</guid><pubDate>{s}</pubDate>", .{ abs, abs, p.fm.date });
        if (p.fm.updated.len > 0) try out.print("<updated>{s}</updated>", .{p.fm.updated});
        if (p.fm.description.len > 0) {
            try out.appendSlice("<description>");
            try appendEscaped(&out, p.fm.description);
            try out.appendSlice("</description>");
        }
        try out.appendSlice("</item>");
    };
    try out.appendSlice("</channel></rss>\n");
    return out.toOwnedSlice();
}

fn renderSitemap(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?><urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">");
    for (pages) |p| if (!p.fm.draft) {
        const abs = try absoluteUrl(allocator, site, p.url);
        try out.print("<url><loc>{s}</loc>", .{abs});
        const lastmod = if (p.fm.updated.len > 0) p.fm.updated else p.fm.date;
        if (lastmod.len > 0) try out.print("<lastmod>{s}</lastmod>", .{lastmod});
        try out.appendSlice("</url>");
    };
    try out.appendSlice("</urlset>\n");
    return out.toOwnedSlice();
}

fn renderSearchIndex(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    _ = site;
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("[\n");
    var first = true;
    for (pages) |p| if (!p.fm.draft) {
        if (!first) try out.appendSlice(",\n");
        first = false;
        try out.appendSlice("  {\"title\":\"");
        try appendJsonEscaped(&out, p.fm.title);
        try out.appendSlice("\",\"url\":\"");
        try appendJsonEscaped(&out, p.url);
        try out.appendSlice("\",\"tags\":[");
        for (p.fm.tags, 0..) |tag, i| {
            if (i > 0) try out.appendSlice(",");
            try out.appendSlice("\"");
            try appendJsonEscaped(&out, tag);
            try out.appendSlice("\"");
        }
        try out.appendSlice("],\"body\":\"");
        try appendJsonEscaped(&out, stripMarkdownForIndex(p.markdown));
        try out.appendSlice("\"}");
    };
    try out.appendSlice("\n]\n");
    return out.toOwnedSlice();
}

fn buildRouteGraph(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig, pages: []Page, assets: AssetGraph) !RouteGraph {
    var graph = RouteGraph.init(allocator);
    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    for (pages) |page| {
        if (page.fm.draft) continue;
        const rel = try outputRelForUrl(allocator, page.url);
        try graph.add(.{
            .kind = if (page.is_post) .post else .page,
            .source_path = page.source_path,
            .url = page.url,
            .out_path = try join(allocator, &.{ out_dir, rel }),
        });
    }
    try graph.add(.{ .kind = .archive, .url = "/archive/", .out_path = try join(allocator, &.{ out_dir, "archive", "index.html" }) });
    try graph.add(.{ .kind = .rss, .url = "/rss.xml", .out_path = try join(allocator, &.{ out_dir, "rss.xml" }) });
    try graph.add(.{ .kind = .sitemap, .url = "/sitemap.xml", .out_path = try join(allocator, &.{ out_dir, "sitemap.xml" }) });
    if (site.search_index) try graph.add(.{ .kind = .search_index, .url = "/search.json", .out_path = try join(allocator, &.{ out_dir, "search.json" }) });
    var seen_tags = std.StringHashMap(void).init(allocator);
    var seen_categories = std.StringHashMap(void).init(allocator);
    for (pages) |page| if (page.is_post and !page.fm.draft) {
        for (page.fm.tags) |tag| {
            const slug = try slugify(allocator, tag);
            if (!seen_tags.contains(slug)) {
                try seen_tags.put(slug, {});
                try graph.add(.{ .kind = .tag, .url = try std.fmt.allocPrint(allocator, "/tags/{s}/", .{slug}), .out_path = try join(allocator, &.{ out_dir, "tags", slug, "index.html" }) });
            }
        }
        for (page.fm.categories) |category| {
            const slug = try slugify(allocator, category);
            if (!seen_categories.contains(slug)) {
                try seen_categories.put(slug, {});
                try graph.add(.{ .kind = .tag, .url = try std.fmt.allocPrint(allocator, "/categories/{s}/", .{slug}), .out_path = try join(allocator, &.{ out_dir, "categories", slug, "index.html" }) });
            }
        }
    };
    for (assets.assets.items) |asset| try graph.add(.{ .kind = .static_asset, .source_path = asset.source_path, .url = asset.url, .out_path = asset.out_path });
    return graph;
}

fn buildAssetGraph(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig) !AssetGraph {
    var graph = AssetGraph.init(allocator);
    const static_dir = try join(allocator, &.{ dir, "static" });
    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try walkStaticAssets(allocator, static_dir, static_dir, out_dir, &graph);
    return graph;
}

fn walkStaticAssets(allocator: std.mem.Allocator, root: []const u8, dir: []const u8, out_dir: []const u8, graph: *AssetGraph) !void {
    var d = std.Io.Dir.cwd().openDir(runtime_io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        const child = try join(allocator, &.{ dir, entry.name });
        switch (entry.kind) {
            .directory => try walkStaticAssets(allocator, root, child, out_dir, graph),
            .file => {
                const rel = std.mem.trimStart(u8, child[root.len..], std.Io.Dir.path.sep_str);
                try graph.add(.{
                    .kind = .site,
                    .source_path = child,
                    .out_path = try join(allocator, &.{ out_dir, rel }),
                    .url = try std.fmt.allocPrint(allocator, "/{s}", .{try slashPath(allocator, rel)}),
                });
            },
            else => {},
        }
    }
}

fn copyAssets(allocator: std.mem.Allocator, assets: AssetGraph) !void {
    for (assets.assets.items) |asset| {
        const data = try std.Io.Dir.cwd().readFileAlloc(runtime_io, asset.source_path, allocator, .limited(64 * 1024 * 1024));
        try writeAll(allocator, asset.out_path, data);
    }
}

fn validateHtmlPages(allocator: std.mem.Allocator, pages: []Page) !void {
    for (pages) |page| try validateHtml(allocator, page.html, page.source_path);
}

fn validateHtml(allocator: std.mem.Allocator, html: []const u8, source_path: []const u8) !void {
    var stack = std.array_list.Managed([]const u8).init(allocator);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |start| {
        if (start + 1 >= html.len) break;
        if (html[start + 1] == '!' or html[start + 1] == '?') {
            i = start + 2;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return fail("malformed HTML tag in {s}", .{source_path});
        const raw = std.mem.trim(u8, html[start + 1 .. end], " \t\r\n");
        if (raw.len == 0) {
            i = end + 1;
            continue;
        }
        const closing = raw[0] == '/';
        const name_start: usize = if (closing) 1 else 0;
        var name_end = name_start;
        while (name_end < raw.len and (std.ascii.isAlphanumeric(raw[name_end]) or raw[name_end] == '-')) name_end += 1;
        if (name_end == name_start) {
            i = end + 1;
            continue;
        }
        const name = raw[name_start..name_end];
        if (std.mem.eql(u8, name, "script") or std.mem.eql(u8, name, "style")) {
            const close_needle = if (std.mem.eql(u8, name, "script")) "</script>" else "</style>";
            i = if (std.mem.indexOfPos(u8, html, end + 1, close_needle)) |close_idx| close_idx + close_needle.len else end + 1;
            continue;
        }
        if (isVoidHtmlTag(name) or std.mem.endsWith(u8, raw, "/")) {
            i = end + 1;
            continue;
        }
        if (closing) {
            if (stack.items.len == 0 or !std.mem.eql(u8, stack.items[stack.items.len - 1], name)) return fail("malformed HTML in {s}: unexpected closing tag </{s}>", .{ source_path, name });
            _ = stack.pop();
        } else {
            try stack.append(name);
        }
        i = end + 1;
    }
    if (stack.items.len > 0) return fail("malformed HTML in {s}: unclosed tag <{s}>", .{ source_path, stack.items[stack.items.len - 1] });
}

fn isVoidHtmlTag(name: []const u8) bool {
    const tags = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };
    for (tags) |tag| if (std.mem.eql(u8, name, tag)) return true;
    return false;
}

fn addImageDimensions(allocator: std.mem.Allocator, html: []const u8, site_dir: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<img ")) |idx| {
        try out.appendSlice(rest[0..idx]);
        const after = rest[idx..];
        const end = std.mem.indexOfScalar(u8, after, '>') orelse {
            try out.appendSlice(after);
            return out.toOwnedSlice();
        };
        const tag = after[0 .. end + 1];
        if (std.mem.indexOf(u8, tag, " width=") == null and std.mem.indexOf(u8, tag, " height=") == null) {
            if (extractAttr(tag, "src")) |src| {
                if (!isExternalUrl(src) and std.mem.startsWith(u8, src, "/")) {
                    const static_path = try join(allocator, &.{ site_dir, "static", std.mem.trimStart(u8, src, "/") });
                    if (try probeImageDimensions(allocator, static_path)) |dim| {
                        try out.appendSlice(tag[0 .. tag.len - 1]);
                        try out.print(" width=\"{d}\" height=\"{d}\">", .{ dim.width, dim.height });
                    } else {
                        try out.appendSlice(tag);
                    }
                } else {
                    try out.appendSlice(tag);
                }
            } else {
                try out.appendSlice(tag);
            }
        } else {
            try out.appendSlice(tag);
        }
        rest = after[end + 1 ..];
    }
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

const ImageDimensions = struct { width: u32, height: u32 };

fn probeImageDimensions(allocator: std.mem.Allocator, path: []const u8) !?ImageDimensions {
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (data.len >= 24 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n")) {
        return .{
            .width = std.mem.readInt(u32, data[16..][0..4], .big),
            .height = std.mem.readInt(u32, data[20..][0..4], .big),
        };
    }
    if (data.len >= 10 and data[0] == 0xff and data[1] == 0xd8) {
        var i: usize = 2;
        while (i + 9 < data.len) {
            if (data[i] != 0xff) {
                i += 1;
                continue;
            }
            const marker = data[i + 1];
            if (marker == 0xc0 or marker == 0xc2) {
                return .{
                    .height = std.mem.readInt(u16, data[i + 5 ..][0..2], .big),
                    .width = std.mem.readInt(u16, data[i + 7 ..][0..2], .big),
                };
            }
            const segment_len = std.mem.readInt(u16, data[i + 2 ..][0..2], .big);
            if (segment_len < 2) break;
            i += 2 + segment_len;
        }
    }
    return null;
}

fn extractAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    const needle = std.fmt.allocPrint(std.heap.page_allocator, "{s}=\"", .{name}) catch return null;
    defer std.heap.page_allocator.free(needle);
    const start = std.mem.indexOf(u8, tag, needle) orelse return null;
    const rest = tag[start + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn permalinkForPage(allocator: std.mem.Allocator, site: SiteConfig, fm: Frontmatter, slug: []const u8, is_post: bool) ![]const u8 {
    const pattern = if (is_post) site.permalink else "/:slug/";
    var out = try replaceAll(allocator, pattern, ":slug", slug);
    if (fm.date.len >= 10) {
        out = try replaceAll(allocator, out, ":year", fm.date[0..4]);
        out = try replaceAll(allocator, out, ":month", fm.date[5..7]);
        out = try replaceAll(allocator, out, ":day", fm.date[8..10]);
    }
    if (!std.mem.startsWith(u8, out, "/")) out = try std.fmt.allocPrint(allocator, "/{s}", .{out});
    if (!std.mem.endsWith(u8, out, "/") and std.mem.lastIndexOfScalar(u8, out, '.') == null) out = try std.fmt.allocPrint(allocator, "{s}/", .{out});
    return out;
}

fn outputRelForUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (std.mem.eql(u8, url, "/")) return allocator.dupe(u8, "index.html");
    if (std.mem.endsWith(u8, url, ".xml") or std.mem.endsWith(u8, url, ".json")) return allocator.dupe(u8, std.mem.trimStart(u8, url, "/"));
    return std.fmt.allocPrint(allocator, "{s}index.html", .{std.mem.trimStart(u8, url, "/")});
}

fn absoluteUrl(allocator: std.mem.Allocator, site: SiteConfig, path: []const u8) ![]const u8 {
    if (site.url.len == 0) return allocator.dupe(u8, path);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ site.url, path });
}

fn resolveLinkUrl(allocator: std.mem.Allocator, base_url: []const u8, raw: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "#")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, raw });
    if (std.mem.startsWith(u8, raw, "/")) return normalizeRouteUrl(allocator, raw);
    const hash_or_query = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const path = raw[0..hash_or_query];
    const suffix = raw[hash_or_query..];
    const base_dir = if (std.mem.endsWith(u8, base_url, "/")) base_url else std.Io.Dir.path.dirname(base_url) orelse "/";
    var parts = std.array_list.Managed([]const u8).init(allocator);
    var base_parts = std.mem.splitScalar(u8, std.mem.trim(u8, base_dir, "/"), '/');
    while (base_parts.next()) |part| if (part.len > 0) try parts.append(part);
    var rel_parts = std.mem.splitScalar(u8, path, '/');
    while (rel_parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            try parts.append(part);
        }
    }
    var out = std.array_list.Managed(u8).init(allocator);
    try out.append('/');
    for (parts.items, 0..) |part, i| {
        if (i > 0) try out.append('/');
        try out.appendSlice(part);
    }
    if (path.len == 0 or std.mem.lastIndexOfScalar(u8, path, '.') == null) try out.append('/');
    try out.appendSlice(suffix);
    return out.toOwnedSlice();
}

fn normalizeRouteUrl(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const hash_or_query = std.mem.indexOfAny(u8, raw, "?#") orelse raw.len;
    const path = raw[0..hash_or_query];
    const suffix = raw[hash_or_query..];
    if (std.mem.eql(u8, path, "/") or std.mem.endsWith(u8, path, "/") or std.mem.lastIndexOfScalar(u8, path, '.') != null) return allocator.dupe(u8, raw);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, suffix });
}

fn isKnownInternalTarget(url: []const u8, source: Page, pages: []Page, routes: RouteGraph, assets: AssetGraph) bool {
    const hash_start = std.mem.indexOfScalar(u8, url, '#');
    const path = if (hash_start) |idx| url[0..idx] else url;
    const hash = if (hash_start) |idx| url[idx + 1 ..] else "";
    const path_ok = routes.containsUrl(path) or assets.containsUrl(path);
    if (!path_ok) return false;
    if (hash.len == 0) return true;
    for (pages) |page| {
        if (std.mem.eql(u8, page.url, path) or (path.len == 0 and std.mem.eql(u8, page.url, source.url))) {
            for (page.toc) |heading| if (std.mem.eql(u8, heading.id, hash)) return true;
        }
    }
    return false;
}

fn isExternalUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "//");
}

fn isPrefetchMode(value: []const u8) bool {
    const modes = [_][]const u8{ "hover", "tap", "viewport", "load", "false" };
    for (modes) |mode| if (std.mem.eql(u8, value, mode)) return true;
    return false;
}

fn validateDuplicateTransitionNames(allocator: std.mem.Allocator, page: Page) !void {
    var seen = std.StringHashMap(void).init(allocator);
    if (page.fm.transition.len > 0) try seen.put(try safeCssIdent(allocator, page.fm.transition), {});
    var rest = page.html;
    while (std.mem.indexOf(u8, rest, "view-transition-name:")) |idx| {
        rest = rest[idx + "view-transition-name:".len ..];
        var end: usize = 0;
        while (end < rest.len and rest[end] != ';' and rest[end] != '"' and rest[end] != '\'') end += 1;
        const name = std.mem.trim(u8, rest[0..end], " \t");
        if (seen.contains(name)) return fail("duplicate view transition name '{s}' in {s}", .{ name, page.source_path });
        try seen.put(name, {});
        rest = rest[end..];
    }
}

fn countPublishedPages(pages: []Page, options: BuildOptions) usize {
    var count: usize = 0;
    for (pages) |page| {
        if (!(options.mode == .production and page.fm.draft)) count += 1;
    }
    return count;
}

fn emptyPage(slug: []const u8, url: []const u8, title: []const u8) Page {
    return .{
        .source_path = "",
        .rel_path = "",
        .slug = slug,
        .url = url,
        .fm = .{ .title = title, .layout = "base.shtml" },
        .markdown = "",
        .html = "",
        .toc = &.{},
        .is_post = false,
    };
}

fn appendJsonEscaped(out: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '\\' => try out.appendSlice("\\\\"),
        '"' => try out.appendSlice("\\\""),
        '\n' => try out.appendSlice("\\n"),
        '\r' => {},
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(c),
    };
}

fn stripMarkdownForIndex(markdown: []const u8) []const u8 {
    return markdown;
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    if (value.len > 1 and std.mem.endsWith(u8, value, "/")) return value[0 .. value.len - 1];
    return value;
}

fn slashPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == std.Io.Dir.path.sep) c.* = '/';
    }
    return out;
}

fn siteFingerprint(allocator: std.mem.Allocator, dir: []const u8) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    try hashPathIfPresent(allocator, &hasher, try join(allocator, &.{ dir, "zlog.ziggy" }));
    try hashTreeIfPresent(allocator, &hasher, try join(allocator, &.{ dir, "content" }));
    try hashTreeIfPresent(allocator, &hasher, try join(allocator, &.{ dir, "layouts" }));
    try hashTreeIfPresent(allocator, &hasher, try join(allocator, &.{ dir, "static" }));
    return hasher.final();
}

fn hashTreeIfPresent(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, path: []const u8) !void {
    var d = std.Io.Dir.cwd().openDir(runtime_io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        const child = try join(allocator, &.{ path, entry.name });
        hasher.update(child);
        switch (entry.kind) {
            .directory => try hashTreeIfPresent(allocator, hasher, child),
            .file => try hashPathIfPresent(allocator, hasher, child),
            else => {},
        }
    }
}

fn hashPathIfPresent(allocator: std.mem.Allocator, hasher: *std.hash.Wyhash, path: []const u8) !void {
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    hasher.update(path);
    hasher.update(data);
}

fn frontmatterFieldLine(markdown: []const u8, name: []const u8) ?usize {
    _ = markdown;
    _ = name;
    return null;
}

fn hasTag(page: Page, tag: []const u8) bool {
    for (page.fm.tags) |t| if (std.mem.eql(u8, t, tag)) return true;
    return false;
}

fn hasCategory(page: Page, category: []const u8) bool {
    for (page.fm.categories) |c| if (std.mem.eql(u8, c, category)) return true;
    return false;
}

fn countPosts(pages: []Page, options: BuildOptions) usize {
    var count: usize = 0;
    for (pages) |page| {
        if (page.is_post and !(options.mode == .production and page.fm.draft)) count += 1;
    }
    return count;
}

fn slugFromPath(rel: []const u8) []const u8 {
    var out = rel;
    if (std.mem.startsWith(u8, out, "posts/")) out = out[6..];
    if (std.mem.endsWith(u8, out, ".md")) out = out[0 .. out.len - 3];
    return out;
}

fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var prev_dash = false;
    for (text) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.append(lower);
            prev_dash = false;
        } else if (!prev_dash and out.items.len > 0) {
            try out.append('-');
            prev_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice("section");
    return out.toOwnedSlice();
}

fn safeCssIdent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return slugify(allocator, text);
}

fn appendEscaped(out: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |c| try appendEscapedChar(out, c);
}
fn appendEscapedChar(out: *std.array_list.Managed(u8), c: u8) !void {
    switch (c) {
        '&' => try out.appendSlice("&amp;"),
        '<' => try out.appendSlice("&lt;"),
        '>' => try out.appendSlice("&gt;"),
        '"' => try out.appendSlice("&quot;"),
        else => try out.append(c),
    }
}

fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        try out.appendSlice(rest[0..idx]);
        try out.appendSlice(replacement);
        rest = rest[idx + needle.len ..];
    }
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    if (parts.len > 0 and std.Io.Dir.path.isAbsolute(parts[0])) try out.append(std.Io.Dir.path.sep);
    for (parts, 0..) |p, i| {
        if (p.len == 0) continue;
        if (i > 0 and out.items.len > 0 and out.items[out.items.len - 1] != std.Io.Dir.path.sep) try out.append(std.Io.Dir.path.sep);
        try out.appendSlice(std.mem.trim(u8, p, std.Io.Dir.path.sep_str));
    }
    return out.toOwnedSlice();
}

fn makeDirPath(path: []const u8) !void {
    try mkdirp(path);
}
fn cleanAndCreate(path: []const u8) !void {
    std.Io.Dir.cwd().deleteTree(runtime_io, path) catch {};
    try mkdirp(path);
}
fn writeAll(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    if (std.Io.Dir.path.dirname(path)) |d| try mkdirp(d);
    try std.Io.Dir.cwd().writeFile(runtime_io, .{ .sub_path = path, .data = text });
    _ = allocator;
}

fn mkdirp(path: []const u8) !void {
    if (path.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(runtime_io, path);
}
fn writeNew(allocator: std.mem.Allocator, base: []const u8, rel: []const u8, text: []const u8) !void {
    try writeAll(allocator, try join(allocator, &.{ base, rel }), text);
}

fn copyStaticIfPresent(allocator: std.mem.Allocator, dir: []const u8, out_dir: []const u8) !void {
    const static_dir = try join(allocator, &.{ dir, "static" });
    var d = std.Io.Dir.cwd().openDir(runtime_io, static_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| if (entry.kind == .file) {
        const src = try join(allocator, &.{ static_dir, entry.name });
        const dst = try join(allocator, &.{ out_dir, entry.name });
        const data = try std.Io.Dir.cwd().readFileAlloc(runtime_io, src, allocator, .limited(32 * 1024 * 1024));
        try writeAll(allocator, dst, data);
    };
}

const initConfig =
    \\.title = "example.dev",
    \\.content_dir = "content",
    \\.layouts_dir = "layouts",
    \\.out_dir = "public",
    \\.navigation = .{
    \\  .prefetch_default = "hover",
    \\  .view_transition = "cross_document",
    \\  .speculation_rules = true,
    \\},
;
const initIndex =
    \\---
    \\.title = "Home",
    \\.layout = "base.shtml",
    \\---
    \\
    \\# example.dev
    \\
    \\Welcome to a zlog site.
;
const initPost =
    \\---
    \\.title = "Hello zlog",
    \\.date = "2026-06-23T00:00:00+09:00",
    \\.tags = ["zig", "ssg"],
    \\.layout = "post.shtml",
    \\.draft = false,
    \\.prefetch = "hover",
    \\.transition = "post-title:hello-zlog",
    \\---
    \\
    \\# Hello zlog
    \\
    \\This is a generated post.
    \\
    \\[Back home](/)
;
const initBaseLayout =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{{page.title}} - {{site.title}}</title>{{zlog.head}}</head>
    \\<body><header><a href="/" data-z-prefetch="hover">{{site.title}}</a></header><main>{{content}}{{post_list}}</main>{{zlog.runtime}}</body></html>
;
const initPostLayout =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{{page.title}} - {{site.title}}</title>{{zlog.head}}</head>
    \\<body><header><a href="/" data-z-prefetch="hover">{{site.title}}</a></header><article><h1 z-transition-name="{{page.transition}}">{{page.title}}</h1><p><time>{{page.date}}</time> {{page.tags}}</p>{{content}}</article>{{zlog.runtime}}</body></html>
;

test "frontmatter parser reads title tags and draft" {
    const text =
        \\.title = "Post",
        \\.tags = ["zig", "ssg"],
        \\.draft = false,
    ;
    const fm = try parseFrontmatter(std.testing.allocator, text);
    defer std.testing.allocator.free(fm.tags);
    try std.testing.expectEqualStrings("Post", fm.title);
    try std.testing.expectEqual(@as(usize, 2), fm.tags.len);
    try std.testing.expect(!fm.draft);
}

test "markdown renderer emits headings paragraphs and links" {
    var headings = std.array_list.Managed(Heading).init(std.testing.allocator);
    defer freeTestHeadings(&headings);
    const html = try markdownToHtml(std.testing.allocator, "# Hello\n\nGo [home](/)", &headings);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"hello\">Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-z-prefetch") != null);
}

test "markdown renderer handles fenced code tables and emphasis" {
    var headings = std.array_list.Managed(Heading).init(std.testing.allocator);
    defer freeTestHeadings(&headings);
    const html = try markdownToHtml(std.testing.allocator,
        \\| Name | Value |
        \\| --- | --- |
        \\| **zlog** | https://example.com |
        \\
        \\```zig
        \\const x = 1;
        \\```
    , &headings);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "language-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>zlog</strong>") != null);
}

fn freeTestHeadings(headings: *std.array_list.Managed(Heading)) void {
    for (headings.items) |heading| std.testing.allocator.free(heading.id);
    headings.deinit();
}

test "transition names are safe css identifiers" {
    const id = try safeCssIdent(std.testing.allocator, "post-title:Hello Zig!");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("post-title-hello-zig", id);
}
