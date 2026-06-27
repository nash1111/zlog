const std = @import("std");
var runtime_io: std.Io = undefined;

const SiteConfig = struct {
    title: []const u8 = "zlog site",
    url: []const u8 = "http://localhost:1111",
    language: []const u8 = "en",
    timezone: []const u8 = "UTC",
    author: []const u8 = "",
    content_dir: []const u8 = "content",
    layouts_dir: []const u8 = "layouts",
    out_dir: []const u8 = "public",
    prefetch_default: []const u8 = "hover",
    speculation_rules: bool = true,
};

const Frontmatter = struct {
    title: []const u8 = "",
    date: []const u8 = "",
    updated: []const u8 = "",
    layout: []const u8 = "base.shtml",
    tags: []const []const u8 = &.{},
    draft: bool = false,
    prefetch: []const u8 = "",
    transition: []const u8 = "",
};

const ContentCollection = enum { page, post };

const Heading = struct {
    level: usize,
    id: []const u8,
    title: []const u8,
};

const cmark = struct {
    const node = opaque {};
    const parser = opaque {};
    const iter = opaque {};
    const syntax_extension = opaque {};
    const llist = opaque {};

    extern fn cmark_gfm_core_extensions_ensure_registered() void;
    extern fn cmark_find_syntax_extension(name: [*:0]const u8) ?*syntax_extension;
    extern fn cmark_parser_new(options: c_int) ?*parser;
    extern fn cmark_parser_free(parser: *parser) void;
    extern fn cmark_parser_feed(parser: *parser, buffer: [*]const u8, len: usize) void;
    extern fn cmark_parser_finish(parser: *parser) ?*node;
    extern fn cmark_parser_attach_syntax_extension(parser: *parser, extension: *syntax_extension) c_int;
    extern fn cmark_parser_get_syntax_extensions(parser: *parser) ?*llist;
    extern fn cmark_render_html(root: *node, options: c_int, extensions: ?*llist) ?[*:0]u8;
    extern fn cmark_node_free(node: *node) void;
    extern fn cmark_node_get_type(node: *node) c_int;
    extern fn cmark_node_get_heading_level(node: *node) c_int;
    extern fn cmark_node_get_string_content(node: *node) ?[*:0]const u8;
    extern fn cmark_iter_new(root: *node) ?*iter;
    extern fn cmark_iter_next(iter: *iter) c_int;
    extern fn cmark_iter_get_node(iter: *iter) ?*node;
    extern fn cmark_iter_free(iter: *iter) void;
    extern fn free(ptr: ?*anyopaque) void;
};

const CMARK_NODE_HEADING: c_int = 0x8000 | 0x0009;
const CMARK_EVENT_DONE: c_int = 1;
const CMARK_EVENT_ENTER: c_int = 2;
const CMARK_OPT_VALIDATE_UTF8: c_int = 1 << 9;
const CMARK_OPT_FOOTNOTES: c_int = 1 << 13;
const CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE: c_int = 1 << 14;
const CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES: c_int = 1 << 15;

const Page = struct {
    source_path: []const u8,
    slug: []const u8,
    url: []const u8,
    fm: Frontmatter,
    markdown: []const u8,
    body_line: usize = 1,
    html: []const u8,
    is_post: bool,
};

const RouteKind = enum { page, post, tag, archive, rss, sitemap, static_asset };

const Route = struct {
    kind: RouteKind,
    source_path: []const u8 = "",
    url: []const u8,
    out_path: []const u8,
};

const RouteGraph = struct {
    allocator: std.mem.Allocator,
    routes: std.array_list.Managed(Route),
    owned_strings: std.array_list.Managed([]const u8),

    fn init(allocator: std.mem.Allocator) RouteGraph {
        return .{
            .allocator = allocator,
            .routes = std.array_list.Managed(Route).init(allocator),
            .owned_strings = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *RouteGraph) void {
        for (self.owned_strings.items) |value| self.allocator.free(value);
        self.owned_strings.deinit();
        self.routes.deinit();
    }

    fn add(self: *RouteGraph, route: Route) !void {
        try self.routes.append(route);
    }

    fn own(self: *RouteGraph, value: []const u8) ![]const u8 {
        errdefer self.allocator.free(value);
        try self.owned_strings.append(value);
        return value;
    }

    fn containsUrl(self: RouteGraph, url: []const u8) bool {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.url, url)) return true;
        }
        return false;
    }

    fn firstByKind(self: RouteGraph, kind: RouteKind) ?Route {
        for (self.routes.items) |route| {
            if (route.kind == kind) return route;
        }
        return null;
    }
};

const AssetKind = enum { page_asset, site_asset, build_asset };

const ImageDimensions = struct {
    width: u32,
    height: u32,
};

const Asset = struct {
    kind: AssetKind,
    owner_path: []const u8 = "",
    source_path: []const u8 = "",
    url: []const u8,
    out_path: []const u8,
    dimensions: ?ImageDimensions = null,
};

const AssetGraph = struct {
    allocator: std.mem.Allocator,
    assets: std.array_list.Managed(Asset),
    owned_strings: std.array_list.Managed([]const u8),

    fn init(allocator: std.mem.Allocator) AssetGraph {
        return .{
            .allocator = allocator,
            .assets = std.array_list.Managed(Asset).init(allocator),
            .owned_strings = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn deinit(self: *AssetGraph) void {
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit();
        self.assets.deinit();
    }

    fn own(self: *AssetGraph, s: []const u8) ![]const u8 {
        errdefer self.allocator.free(s);
        try self.owned_strings.append(s);
        return s;
    }

    fn add(self: *AssetGraph, asset: Asset) !void {
        try self.assets.append(asset);
    }

    fn countByKind(self: AssetGraph, kind: AssetKind) usize {
        var count: usize = 0;
        for (self.assets.items) |asset| {
            if (asset.kind == kind) count += 1;
        }
        return count;
    }

    fn firstByKindAndUrl(self: AssetGraph, kind: AssetKind, url: []const u8) ?Asset {
        for (self.assets.items) |asset| {
            if (asset.kind == kind and std.mem.eql(u8, asset.url, url)) return asset;
        }
        return null;
    }
};

const CliError = error{Usage};
const default_dev_port: u16 = 1111;
const watch_poll_interval_ms: i64 = 750;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.InvalidSite => std.process.exit(1),
        error.Usage => std.process.exit(2),
        else => return err,
    };
}

fn run(init: std.process.Init) !void {
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
        try cmdBuild(allocator, dir);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        const port = if (args.len >= 4) std.fmt.parseInt(u16, args[3], 10) catch {
            try stderr("invalid port: {s}\n\n", .{args[3]});
            try printHelp();
            return CliError.Usage;
        } else default_dev_port;
        try cmdDev(allocator, dir, port);
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
        \\  zlog dev [dir] [port]
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
    var routes = try buildRouteGraph(allocator, dir, site, pages.items);
    defer routes.deinit();
    var assets = try buildAssetGraph(allocator, pages.items, routes);
    defer assets.deinit();
    try validatePages(allocator, pages.items, routes);
    try validateRenderedHtml(allocator, dir, site, pages.items, routes, assets);
    try stdout("check ok: {d} pages\n", .{pages.items.len});
}

fn cmdBuild(allocator: std.mem.Allocator, dir: []const u8) !void {
    const site = try loadSite(allocator, dir);
    var pages = try loadPages(allocator, dir, site);
    defer pages.deinit();
    var routes = try buildRouteGraph(allocator, dir, site, pages.items);
    defer routes.deinit();
    var assets = try buildAssetGraph(allocator, pages.items, routes);
    defer assets.deinit();
    try validatePages(allocator, pages.items, routes);

    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try cleanAndCreate(out_dir);
    try copySiteAssets(allocator, assets);

    const post_list = try renderPostList(allocator, pages.items, site);
    const head = try renderHead(allocator, site);
    defer allocator.free(head);
    const runtime = prefetchRuntime;

    for (pages.items) |page| {
        if (page.fm.draft) continue;
        const route = findPageRoute(routes, page.url) orelse return fail("missing route for {s}", .{page.url});
        const layout = try loadLayoutForPage(allocator, dir, site, page);
        const final_html = try renderPageOutputHtml(allocator, layout, site, page, page.html, post_list, head, runtime, route.out_path, assets);
        try writeAll(allocator, route.out_path, final_html);
    }

    try renderTagPages(allocator, routes, pages.items, site, head, runtime);
    try renderArchivePage(allocator, routes, pages.items, site, head, runtime);
    const rss_route = routes.firstByKind(.rss) orelse return fail("missing RSS route", .{});
    const rss_xml = try renderRss(allocator, pages.items, site);
    defer allocator.free(rss_xml);
    try writeAll(allocator, rss_route.out_path, rss_xml);
    const sitemap_route = routes.firstByKind(.sitemap) orelse return fail("missing sitemap route", .{});
    const sitemap_xml = try renderSitemap(allocator, routes, pages.items, site);
    defer allocator.free(sitemap_xml);
    try writeAll(allocator, sitemap_route.out_path, sitemap_xml);
    try stdout("built {d} pages into {s}\n", .{ countPublishedPages(pages.items), out_dir });
}

fn cmdDev(allocator: std.mem.Allocator, dir: []const u8, port: u16) !void {
    try cmdBuild(allocator, dir);
    const site = try loadSite(allocator, dir);
    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try startDevWatcher(allocator, dir);
    try serveDirectory(allocator, out_dir, port);
}

fn startDevWatcher(allocator: std.mem.Allocator, dir: []const u8) !void {
    var thread = try std.Thread.spawn(.{}, watchAndRebuild, .{ allocator, dir });
    thread.detach();
    try stdout("watching zlog.ziggy, content, layouts, and static for rebuilds\n", .{});
}

fn watchAndRebuild(allocator: std.mem.Allocator, dir: []const u8) void {
    var site = loadSite(allocator, dir) catch SiteConfig{};
    var previous = projectFingerprint(allocator, dir, site) catch |err| {
        stderr("watch error: initial scan failed: {t}\n", .{err}) catch {};
        return;
    };

    while (true) {
        std.Io.Clock.Duration.sleep(.{ .raw = std.Io.Duration.fromMilliseconds(watch_poll_interval_ms), .clock = .boot }, runtime_io) catch return;

        const next = projectFingerprint(allocator, dir, site) catch |err| {
            stderr("watch error: scan failed: {t}\n", .{err}) catch {};
            continue;
        };
        if (next == previous) continue;
        previous = next;

        stdout("change detected; rebuilding...\n", .{}) catch {};
        cmdBuild(allocator, dir) catch |err| {
            stderr("watch rebuild failed: {t}\n", .{err}) catch {};
            continue;
        };
        site = loadSite(allocator, dir) catch site;
        previous = projectFingerprint(allocator, dir, site) catch previous;
        stdout("watch rebuild complete\n", .{}) catch {};
    }
}

fn projectFingerprint(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    try fingerprintPath(allocator, try join(allocator, &.{ dir, "zlog.ziggy" }), &hasher);
    try fingerprintPath(allocator, try join(allocator, &.{ dir, site.content_dir }), &hasher);
    try fingerprintPath(allocator, try join(allocator, &.{ dir, site.layouts_dir }), &hasher);
    try fingerprintPath(allocator, try join(allocator, &.{ dir, "static" }), &hasher);
    return hasher.final();
}

fn fingerprintPath(allocator: std.mem.Allocator, path: []const u8, hasher: *std.hash.Wyhash) !void {
    defer allocator.free(path);
    hasher.update(path);
    const stat = std.Io.Dir.cwd().statFile(runtime_io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            hasher.update("missing");
            return;
        },
        else => return err,
    };
    hashFileStat(hasher, stat);
    if (stat.kind != .directory) return;

    var dir = std.Io.Dir.cwd().openDir(runtime_io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(runtime_io);

    var names = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit();
    }

    var it = dir.iterate();
    while (try it.next(runtime_io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);

    for (names.items) |name| {
        try fingerprintPath(allocator, try join(allocator, &.{ path, name }), hasher);
    }
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn hashFileStat(hasher: *std.hash.Wyhash, stat: std.Io.File.Stat) void {
    hasher.update(@tagName(stat.kind));
    hasher.update(std.mem.asBytes(&stat.size));
    hasher.update(std.mem.asBytes(&stat.mtime.nanoseconds));
}

fn serveDirectory(allocator: std.mem.Allocator, root_dir: []const u8, port: u16) !void {
    const net = std.Io.net;
    var address = try net.IpAddress.parse("127.0.0.1", port);
    var server = try address.listen(runtime_io, .{ .reuse_address = true });
    defer server.deinit(runtime_io);

    const actual_port = server.socket.address.getPort();
    try stdout("serving {s} at http://127.0.0.1:{d}/\n", .{ root_dir, actual_port });
    try stdout("press Ctrl+C to stop\n", .{});

    while (true) {
        const stream = server.accept(runtime_io) catch |err| switch (err) {
            error.Canceled => return,
            else => return err,
        };
        try handleDevConnection(allocator, root_dir, stream);
    }
}

fn handleDevConnection(allocator: std.mem.Allocator, root_dir: []const u8, stream: std.Io.net.Stream) !void {
    var connection = stream;
    defer connection.close(runtime_io);

    var send_buffer: [16 * 1024]u8 = undefined;
    var recv_buffer: [16 * 1024]u8 = undefined;
    var connection_reader = connection.reader(runtime_io, &recv_buffer);
    var connection_writer = connection.writer(runtime_io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try serveDevRequest(allocator, root_dir, &request);
    }
}

fn serveDevRequest(allocator: std.mem.Allocator, root_dir: []const u8, request: *std.http.Server.Request) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) {
        return request.respond("method not allowed\n", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Allow", .value = "GET, HEAD" },
            },
        });
    }

    const target_path = requestTargetPath(request.head.target);
    if (!std.mem.startsWith(u8, target_path, "/")) {
        return request.respond("bad request\n", .{
            .status = .bad_request,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
        });
    }

    const file_path = try servedFilePath(allocator, root_dir, target_path);
    defer allocator.free(file_path);
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io, file_path, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return request.respond("not found\n", .{
            .status = .not_found,
            .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
        }),
        else => {
            try request.respond("internal server error\n", .{
                .status = .internal_server_error,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" }},
            });
            return err;
        },
    };
    defer allocator.free(data);

    try request.respond(data, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = contentTypeForPath(file_path) },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
    });
}

fn requestTargetPath(target: []const u8) []const u8 {
    var end = target.len;
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| end = @min(end, idx);
    if (std.mem.indexOfScalar(u8, target, '#')) |idx| end = @min(end, idx);
    return target[0..end];
}

fn servedFilePath(allocator: std.mem.Allocator, root_dir: []const u8, target_path: []const u8) ![]const u8 {
    const normalized = try normalizeUrlPath(allocator, target_path);
    defer allocator.free(normalized);

    var rel_alloc: ?[]const u8 = null;
    defer if (rel_alloc) |rel| allocator.free(rel);

    const rel = if (std.mem.eql(u8, normalized, "/"))
        "index.html"
    else if (std.mem.endsWith(u8, normalized, "/")) rel: {
        rel_alloc = try std.fmt.allocPrint(allocator, "{s}index.html", .{std.mem.trimStart(u8, normalized, "/")});
        break :rel rel_alloc.?;
    } else if (!urlPathHasExtension(normalized)) rel: {
        rel_alloc = try std.fmt.allocPrint(allocator, "{s}/index.html", .{std.mem.trimStart(u8, normalized, "/")});
        break :rel rel_alloc.?;
    } else std.mem.trimStart(u8, normalized, "/");

    return join(allocator, &.{ root_dir, rel });
}

fn contentTypeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html") or std.mem.endsWith(u8, path, ".htm")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".xml")) return "application/xml; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

const LayoutSource = struct {
    path: []const u8,
    html: []const u8,
};

fn loadLayoutForPage(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig, page: Page) !LayoutSource {
    const layout_name = if (page.fm.layout.len == 0) "base.shtml" else page.fm.layout;
    const layout_path = try join(allocator, &.{ dir, site.layouts_dir, layout_name });
    const layout = std.Io.Dir.cwd().readFileAlloc(runtime_io, layout_path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => if (page.is_post) initPostLayout else initBaseLayout,
        else => return err,
    };
    return .{ .path = layout_path, .html = layout };
}

fn validateRenderedHtml(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig, pages: []Page, routes: RouteGraph, assets: AssetGraph) !void {
    const post_list = try renderPostList(allocator, pages, site);
    const head = try renderHead(allocator, site);
    defer allocator.free(head);
    const runtime = prefetchRuntime;

    for (pages) |page| {
        if (page.fm.draft) continue;
        const route = findPageRoute(routes, page.url) orelse return fail("missing route for {s}", .{page.url});
        const layout = try loadLayoutForPage(allocator, dir, site, page);
        const final_html = try renderPageOutputHtml(allocator, layout, site, page, page.html, post_list, head, runtime, route.out_path, assets);
        allocator.free(final_html);
    }

    try validateGeneratedListingHtml(allocator, routes, pages, site, head, runtime);
}

fn renderPageOutputHtml(allocator: std.mem.Allocator, layout: LayoutSource, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8, output_path: []const u8, assets: AssetGraph) ![]const u8 {
    try validateHtmlDocument(allocator, layout.html, layout.path);
    const rendered = try renderLayout(allocator, layout.html, layout.path, site, page, content, post_list, head, runtime);
    defer allocator.free(rendered);
    const final_html = try rewriteNavigationAttributes(allocator, rendered, site.prefetch_default);
    defer allocator.free(final_html);
    const sized_html = try applyImageDimensions(allocator, final_html, page.url, assets);
    errdefer allocator.free(sized_html);
    try validateHtmlDocument(allocator, sized_html, output_path);
    return sized_html;
}

fn validateGeneratedListingHtml(allocator: std.mem.Allocator, routes: RouteGraph, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |tag_slug| allocator.free(tag_slug.*);
        seen.deinit();
    }

    for (pages) |p| {
        if (!p.is_post or p.fm.draft) continue;
        for (p.fm.tags) |tag| {
            const tag_slug = try slugify(allocator, tag);
            if (seen.contains(tag_slug)) {
                allocator.free(tag_slug);
                continue;
            }
            seen.put(tag_slug, {}) catch |err| {
                allocator.free(tag_slug);
                return err;
            };
            const tag_url = try std.fmt.allocPrint(allocator, "/tags/{s}/", .{tag_slug});
            defer allocator.free(tag_url);
            const route = findRoute(routes, .tag, tag_url) orelse return fail("missing tag route for {s}", .{tag_url});
            const rendered = try renderTagPageHtml(allocator, tag, tag_slug, pages, site, head, runtime);
            defer allocator.free(rendered);
            try validateHtmlDocument(allocator, rendered, route.out_path);
        }
    }

    const archive_route = routes.firstByKind(.archive) orelse return fail("missing archive route", .{});
    const archive = try renderArchivePageHtml(allocator, pages, site, head, runtime);
    defer allocator.free(archive);
    try validateHtmlDocument(allocator, archive, archive_route.out_path);
}

fn loadSite(allocator: std.mem.Allocator, dir: []const u8) !SiteConfig {
    const path = try join(allocator, &.{ dir, "zlog.ziggy" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return SiteConfig{},
        else => return err,
    };
    const doc = try parseZiggyFields(allocator, text, path, 1);
    defer allocator.free(doc.fields);
    const site = SiteConfig{
        .title = try ziggyString(doc, path, "title", "zlog site"),
        .url = try ziggyString(doc, path, "url", "http://localhost:1111"),
        .language = try ziggyString(doc, path, "language", "en"),
        .timezone = try ziggyString(doc, path, "timezone", "UTC"),
        .author = try ziggyString(doc, path, "author", ""),
        .content_dir = try ziggyString(doc, path, "content_dir", "content"),
        .layouts_dir = try ziggyString(doc, path, "layouts_dir", "layouts"),
        .out_dir = try ziggyString(doc, path, "out_dir", "public"),
        .prefetch_default = try ziggyString(doc, path, "prefetch_default", "hover"),
        .speculation_rules = try ziggyBool(doc, path, "speculation_rules", true),
    };
    try validateSiteConfig(site, path);
    return site;
}

fn validateSiteConfig(site: SiteConfig, path: []const u8) !void {
    if (!validSiteUrl(site.url)) return failAtHint(path, 1, 1, "invalid site url '{s}'", .{site.url}, "Set .url to an absolute http:// or https:// URL.");
    if (!validLanguageTag(site.language)) return failAtHint(path, 1, 1, "invalid language tag '{s}'", .{site.language}, "Use a BCP47-style language tag such as en or en-US.");
    if (!validTimezone(site.timezone)) return failAtHint(path, 1, 1, "invalid timezone '{s}'", .{site.timezone}, "Use UTC, an offset such as +09:00, or an IANA-style name such as Asia/Tokyo.");
    if (!validAuthor(site.author)) return failAtHint(path, 1, 1, "invalid author value", .{}, "Keep .author to a single line without control characters.");
}

fn validSiteUrl(url: []const u8) bool {
    const has_supported_scheme = std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    if (!has_supported_scheme) return false;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    if (url.len <= scheme_end + 3) return false;
    for (url) |c| if (std.ascii.isWhitespace(c)) return false;
    return true;
}

fn validLanguageTag(language: []const u8) bool {
    if (language.len == 0 or language[0] == '-' or language[language.len - 1] == '-') return false;
    var part_len: usize = 0;
    var part_count: usize = 0;
    for (language) |c| {
        if (c == '-') {
            if (part_len == 0 or part_len > 8) return false;
            part_count += 1;
            part_len = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c)) return false;
        part_len += 1;
    }
    if (part_len == 0 or part_len > 8) return false;
    return part_count < 8;
}

fn validTimezone(timezone: []const u8) bool {
    if (std.mem.eql(u8, timezone, "UTC")) return true;
    if (parseTimezoneOffset(timezone) != null) return true;
    return validTimezoneName(timezone);
}

fn validTimezoneName(timezone: []const u8) bool {
    if (timezone.len == 0 or timezone[0] == '/' or timezone[timezone.len - 1] == '/') return false;
    var has_slash = false;
    for (timezone) |c| {
        if (c == '/') {
            has_slash = true;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '+')) return false;
    }
    return has_slash;
}

fn validAuthor(author: []const u8) bool {
    if (author.len > 256) return false;
    for (author) |c| if (std.ascii.isControl(c)) return false;
    return true;
}

fn loadPages(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig) !std.array_list.Managed(Page) {
    var pages = std.array_list.Managed(Page).init(allocator);
    const content_root = try join(allocator, &.{ dir, site.content_dir });
    try walkMarkdown(allocator, content_root, content_root, &pages);
    std.mem.sort(Page, pages.items, {}, pageLessThan);
    return pages;
}

fn pageLessThan(_: void, a: Page, b: Page) bool {
    if (a.is_post != b.is_post) return !a.is_post;
    return std.mem.order(u8, b.fm.date, a.fm.date) == .lt;
}

fn walkMarkdown(allocator: std.mem.Allocator, root: []const u8, dir: []const u8, pages: *std.array_list.Managed(Page)) !void {
    var d = std.Io.Dir.cwd().openDir(runtime_io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        const child = try join(allocator, &.{ dir, entry.name });
        switch (entry.kind) {
            .directory => try walkMarkdown(allocator, root, child, pages),
            .file => if (std.mem.endsWith(u8, entry.name, ".md")) {
                try pages.append(try loadPage(allocator, root, child));
            },
            else => {},
        }
    }
}

fn loadPage(allocator: std.mem.Allocator, content_root: []const u8, path: []const u8) !Page {
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(8 * 1024 * 1024));
    const split = splitFrontmatter(text);
    const rel = std.mem.trimStart(u8, path[content_root.len..], std.Io.Dir.path.sep_str);
    const is_post = std.mem.startsWith(u8, rel, "posts/");
    const fm = try parseFrontmatter(allocator, split.frontmatter, path, split.frontmatter_line, if (is_post) .post else .page);
    const slug = slugFromPath(rel);
    const url = if (std.mem.eql(u8, rel, "index.md")) try allocator.dupe(u8, "/") else try std.fmt.allocPrint(allocator, "/{s}/", .{slug});
    const html = try markdownToHtml(allocator, split.body);
    return Page{ .source_path = path, .slug = slug, .url = url, .fm = fm, .markdown = split.body, .body_line = split.body_line, .html = html, .is_post = is_post };
}

const FrontmatterSplit = struct {
    frontmatter: []const u8,
    body: []const u8,
    frontmatter_line: usize,
    body_line: usize,
};

fn splitFrontmatter(text: []const u8) FrontmatterSplit {
    if (!std.mem.startsWith(u8, text, "---")) return .{ .frontmatter = "", .body = text, .frontmatter_line = 1, .body_line = 1 };
    const rest = text[3..];
    if (std.mem.indexOf(u8, rest, "\n---")) |idx| {
        const body_start = 3 + idx + 4;
        const body_raw = text[body_start..];
        const body = std.mem.trimStart(u8, body_raw, "\r\n");
        const body_index = body_start + (body_raw.len - body.len);
        return .{ .frontmatter = std.mem.trim(u8, rest[0..idx], " \t\r\n"), .body = body, .frontmatter_line = 2, .body_line = sourceLocationAt(text, body_index).line };
    }
    return .{ .frontmatter = "", .body = text, .frontmatter_line = 1, .body_line = 1 };
}

fn parseFrontmatter(allocator: std.mem.Allocator, text: []const u8, path: []const u8, line_start: usize, collection: ContentCollection) !Frontmatter {
    const doc = try parseZiggyFields(allocator, text, path, line_start);
    defer allocator.free(doc.fields);
    return Frontmatter{
        .title = try ziggyRequiredString(doc, path, line_start, "title"),
        .date = if (collection == .post) try ziggyRequiredString(doc, path, line_start, "date") else try ziggyString(doc, path, "date", ""),
        .updated = try ziggyString(doc, path, "updated", ""),
        .layout = try ziggyString(doc, path, "layout", "base.shtml"),
        .tags = try ziggyStringArray(doc, path, "tags"),
        .draft = try ziggyBool(doc, path, "draft", false),
        .prefetch = try ziggyString(doc, path, "prefetch", ""),
        .transition = try ziggyString(doc, path, "transition", ""),
    };
}

const ZiggyValue = union(enum) {
    string: []const u8,
    bool: bool,
    string_array: []const []const u8,
    object,
};

const ZiggyField = struct {
    name: []const u8,
    value: ZiggyValue,
    line: usize,
    column: usize,
};

const ZiggyDoc = struct {
    fields: []const ZiggyField,

    fn find(self: ZiggyDoc, name: []const u8) ?ZiggyField {
        var i = self.fields.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.fields[i].name, name)) return self.fields[i];
        }
        return null;
    }
};

fn parseZiggyFields(allocator: std.mem.Allocator, text: []const u8, path: []const u8, line_start: usize) !ZiggyDoc {
    var parser = ZiggyParser{
        .allocator = allocator,
        .path = path,
        .text = text,
        .line = line_start,
        .fields = std.array_list.Managed(ZiggyField).init(allocator),
    };
    while (true) {
        try parser.skipIgnored();
        if (parser.isDone()) break;
        if (parser.peek() == '}') return parser.fail("unexpected object close", .{});
        try parser.parseField();
    }
    return .{ .fields = try parser.fields.toOwnedSlice() };
}

const ZiggyParser = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    fields: std.array_list.Managed(ZiggyField),

    fn isDone(self: ZiggyParser) bool {
        return self.index >= self.text.len;
    }

    fn peek(self: ZiggyParser) u8 {
        return if (self.isDone()) 0 else self.text[self.index];
    }

    fn advance(self: *ZiggyParser) u8 {
        const c = self.text[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn fail(self: ZiggyParser, comptime fmt: []const u8, args: anytype) anyerror {
        failAt(self.path, self.line, self.column, fmt, args) catch |err| return err;
        return error.InvalidSite;
    }

    fn failHint(self: ZiggyParser, comptime fmt: []const u8, args: anytype, hint: []const u8) anyerror {
        failAtHint(self.path, self.line, self.column, fmt, args, hint) catch |err| return err;
        return error.InvalidSite;
    }

    fn skipIgnored(self: *ZiggyParser) !void {
        while (!self.isDone()) {
            switch (self.peek()) {
                ' ', '\t', '\r', '\n', ',' => _ = self.advance(),
                '/' => {
                    if (self.index + 1 < self.text.len and self.text[self.index + 1] == '/') {
                        while (!self.isDone() and self.peek() != '\n') _ = self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn expect(self: *ZiggyParser, expected: u8) !void {
        if (self.isDone() or self.peek() != expected) return self.failHint("expected '{c}'", .{expected}, "Use Ziggy field syntax such as .title = \"...\".");
        _ = self.advance();
    }

    fn parseField(self: *ZiggyParser) anyerror!void {
        const field_line = self.line;
        const field_column = self.column;
        try self.expect('.');
        const name = try self.parseIdentifier();
        try self.skipIgnored();
        try self.expect('=');
        try self.skipIgnored();
        const value = try self.parseValue();
        try self.fields.append(.{ .name = name, .value = value, .line = field_line, .column = field_column });
    }

    fn parseIdentifier(self: *ZiggyParser) anyerror![]const u8 {
        if (self.isDone() or !(std.ascii.isAlphabetic(self.peek()) or self.peek() == '_')) {
            return self.failHint("expected field name", .{}, "Field names start with a dot, for example .title.");
        }
        const start = self.index;
        while (!self.isDone() and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) _ = self.advance();
        return self.text[start..self.index];
    }

    fn parseValue(self: *ZiggyParser) anyerror!ZiggyValue {
        return switch (self.peek()) {
            '"' => .{ .string = try self.parseString() },
            '[' => .{ .string_array = try self.parseStringArray() },
            't', 'f' => .{ .bool = try self.parseBool() },
            '.' => blk: {
                _ = self.advance();
                try self.expect('{');
                while (true) {
                    try self.skipIgnored();
                    if (self.isDone()) return self.failHint("unterminated object", .{}, "Close the object with }.");
                    if (self.peek() == '}') {
                        _ = self.advance();
                        break;
                    }
                    try self.parseField();
                }
                break :blk .object;
            },
            else => self.failHint("unsupported Ziggy value", .{}, "Use a string, bool, string array, or .{ ... } object value."),
        };
    }

    fn parseString(self: *ZiggyParser) anyerror![]const u8 {
        try self.expect('"');
        const start = self.index;
        while (!self.isDone()) {
            const c = self.peek();
            if (c == '"') {
                const value = self.text[start..self.index];
                _ = self.advance();
                return value;
            }
            if (c == '\n') return self.failHint("unterminated string", .{}, "Close the string with a matching quote.");
            if (c == '\\') {
                _ = self.advance();
                if (self.isDone()) return self.failHint("unterminated escape sequence", .{}, "Add the escaped character after the backslash.");
            }
            _ = self.advance();
        }
        return self.failHint("unterminated string", .{}, "Close the string with a matching quote.");
    }

    fn parseStringArray(self: *ZiggyParser) anyerror![]const []const u8 {
        try self.expect('[');
        var values = std.array_list.Managed([]const u8).init(self.allocator);
        while (true) {
            try self.skipIgnored();
            if (self.isDone()) return self.failHint("unterminated array", .{}, "Close the array with ].");
            if (self.peek() == ']') {
                _ = self.advance();
                return values.toOwnedSlice();
            }
            if (self.peek() != '"') return self.failHint("expected string in array", .{}, "Use quoted string entries, for example [\"zig\", \"ssg\"].");
            try values.append(try self.parseString());
        }
    }

    fn parseBool(self: *ZiggyParser) anyerror!bool {
        if (std.mem.startsWith(u8, self.text[self.index..], "true")) {
            self.index += 4;
            self.column += 4;
            return true;
        }
        if (std.mem.startsWith(u8, self.text[self.index..], "false")) {
            self.index += 5;
            self.column += 5;
            return false;
        }
        return self.failHint("expected bool", .{}, "Use true or false without quotes.");
    }
};

fn ziggyString(doc: ZiggyDoc, path: []const u8, name: []const u8, default: []const u8) ![]const u8 {
    const field = doc.find(name) orelse return default;
    return switch (field.value) {
        .string => |value| value,
        else => {
            try failAtHint(path, field.line, field.column, ".{s} must be a string", .{name}, "Use a quoted string value.");
            unreachable;
        },
    };
}

fn ziggyRequiredString(doc: ZiggyDoc, path: []const u8, line: usize, name: []const u8) ![]const u8 {
    const field = doc.find(name) orelse {
        try failAtHint(path, line, 1, "missing required field .{s}", .{name}, "Add the field to the frontmatter block.");
        unreachable;
    };
    return switch (field.value) {
        .string => |value| if (value.len > 0) value else {
            try failAtHint(path, field.line, field.column, ".{s} must not be empty", .{name}, "Provide a non-empty quoted string value.");
            unreachable;
        },
        else => {
            try failAtHint(path, field.line, field.column, ".{s} must be a string", .{name}, "Use a quoted string value.");
            unreachable;
        },
    };
}

fn ziggyBool(doc: ZiggyDoc, path: []const u8, name: []const u8, default: bool) !bool {
    const field = doc.find(name) orelse return default;
    return switch (field.value) {
        .bool => |value| value,
        else => {
            try failAtHint(path, field.line, field.column, ".{s} must be a bool", .{name}, "Use true or false without quotes.");
            unreachable;
        },
    };
}

fn ziggyStringArray(doc: ZiggyDoc, path: []const u8, name: []const u8) ![]const []const u8 {
    const field = doc.find(name) orelse return &.{};
    return switch (field.value) {
        .string_array => |value| value,
        else => {
            try failAtHint(path, field.line, field.column, ".{s} must be an array of strings", .{name}, "Use an array such as [\"zig\", \"ssg\"].");
            unreachable;
        },
    };
}

fn markdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    const options: c_int = CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_FOOTNOTES | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE | CMARK_OPT_TABLE_PREFER_STYLE_ATTRIBUTES;
    var headings = std.array_list.Managed(Heading).init(allocator);
    defer freeHeadings(allocator, &headings);

    cmark.cmark_gfm_core_extensions_ensure_registered();
    const parser = cmark.cmark_parser_new(options) orelse return error.MarkdownParserUnavailable;
    defer cmark.cmark_parser_free(parser);
    try attachCmarkExtensions(parser);

    if (markdown.len > 0) cmark.cmark_parser_feed(parser, markdown.ptr, markdown.len);
    const root = cmark.cmark_parser_finish(parser) orelse return error.MarkdownParserUnavailable;
    defer cmark.cmark_node_free(root);

    try collectCmarkHeadings(allocator, root, &headings);

    const html_c = cmark.cmark_render_html(root, options, cmark.cmark_parser_get_syntax_extensions(parser)) orelse return error.MarkdownParserUnavailable;
    defer cmark.free(@ptrCast(html_c));
    const rendered = try allocator.dupe(u8, std.mem.span(html_c));
    defer allocator.free(rendered);

    const with_heading_ids = try addHeadingIdsToHtml(allocator, rendered, headings.items);
    defer allocator.free(with_heading_ids);
    return addPrefetchPlaceholders(allocator, with_heading_ids);
}

fn attachCmarkExtensions(parser: *cmark.parser) !void {
    const extension_names = [_][*:0]const u8{ "table", "strikethrough", "autolink", "tagfilter", "tasklist" };
    for (extension_names) |name| {
        const extension = cmark.cmark_find_syntax_extension(name) orelse return error.MarkdownExtensionUnavailable;
        if (cmark.cmark_parser_attach_syntax_extension(parser, extension) == 0) return error.MarkdownExtensionUnavailable;
    }
}

fn collectCmarkHeadings(allocator: std.mem.Allocator, root: *cmark.node, headings: *std.array_list.Managed(Heading)) !void {
    const it = cmark.cmark_iter_new(root) orelse return error.MarkdownParserUnavailable;
    defer cmark.cmark_iter_free(it);

    while (true) {
        const event = cmark.cmark_iter_next(it);
        if (event == CMARK_EVENT_DONE) break;
        if (event != CMARK_EVENT_ENTER) continue;

        const current = cmark.cmark_iter_get_node(it) orelse continue;
        if (cmark.cmark_node_get_type(current) != CMARK_NODE_HEADING) continue;

        const level: usize = @intCast(cmark.cmark_node_get_heading_level(current));
        if (level == 0) continue;
        const raw_title = if (cmark.cmark_node_get_string_content(current)) |title| std.mem.span(title) else "";
        const title = try allocator.dupe(u8, raw_title);
        errdefer allocator.free(title);
        const id = try slugify(allocator, raw_title);
        errdefer allocator.free(id);
        try headings.append(.{ .level = level, .id = id, .title = title });
    }
}

fn freeHeadings(allocator: std.mem.Allocator, headings: *std.array_list.Managed(Heading)) void {
    for (headings.items) |heading| {
        allocator.free(heading.id);
        allocator.free(heading.title);
    }
    headings.deinit();
}

fn addHeadingIdsToHtml(allocator: std.mem.Allocator, html: []const u8, headings: []const Heading) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    var heading_index: usize = 0;
    while (i < html.len) {
        if (i + 3 < html.len and html[i] == '<' and html[i + 1] == 'h' and html[i + 2] >= '1' and html[i + 2] <= '6' and (html[i + 3] == '>' or std.ascii.isWhitespace(html[i + 3]))) {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const tag = html[i .. end + 1];
            if (heading_index < headings.len and std.mem.indexOf(u8, tag, " id=") == null) {
                try out.appendSlice(html[i..end]);
                try out.print(" id=\"{s}\">", .{headings[heading_index].id});
            } else {
                try out.appendSlice(tag);
            }
            heading_index += 1;
            i = end + 1;
            continue;
        }
        try out.append(html[i]);
        i += 1;
    }
    if (i < html.len) try out.appendSlice(html[i..]);
    return out.toOwnedSlice();
}

fn addPrefetchPlaceholders(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "<a ")) {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const tag = html[i .. end + 1];
            if (std.mem.indexOf(u8, tag, " href=") != null and std.mem.indexOf(u8, tag, "data-z-prefetch") == null) {
                try out.appendSlice(html[i..end]);
                try out.appendSlice(" data-z-prefetch>");
            } else {
                try out.appendSlice(tag);
            }
            i = end + 1;
            continue;
        } else {
            try out.append(html[i]);
            i += 1;
        }
    }
    if (i < html.len) try out.appendSlice(html[i..]);
    return out.toOwnedSlice();
}

fn validatePages(allocator: std.mem.Allocator, pages: []Page, routes: RouteGraph) !void {
    for (pages) |page| {
        if (page.fm.title.len == 0) return failAtHint(page.source_path, 1, 1, "missing .title", .{}, "Add .title = \"...\" to the frontmatter block.");
        if (page.is_post and page.fm.date.len == 0) return failAtHint(page.source_path, 1, 1, "missing .date in post", .{}, "Posts must include .date = \"...\" in frontmatter.");
        try validateDuplicateHeadings(allocator, page);
        try validateInternalLinks(allocator, page, pages, routes);
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    return failHint(fmt, args, "");
}

fn failHint(comptime fmt: []const u8, args: anytype, hint: []const u8) !void {
    try stderr("error: " ++ fmt ++ "\n", args);
    if (hint.len > 0) try stderr("  hint: {s}\n", .{hint});
    return error.InvalidSite;
}

fn failAt(path: []const u8, line: usize, column: usize, comptime fmt: []const u8, args: anytype) !void {
    return failAtHint(path, line, column, fmt, args, "");
}

fn failAtHint(path: []const u8, line: usize, column: usize, comptime fmt: []const u8, args: anytype, hint: []const u8) !void {
    try stderr("{s}:{d}:{d}: error: " ++ fmt ++ "\n", .{ path, line, column } ++ args);
    if (hint.len > 0) try stderr("  hint: {s}\n", .{hint});
    return error.InvalidSite;
}

fn validateDuplicateHeadings(allocator: std.mem.Allocator, page: Page) !void {
    var ids = std.StringHashMap(void).init(allocator);
    defer {
        var keys = ids.keyIterator();
        while (keys.next()) |id| allocator.free(id.*);
        ids.deinit();
    }

    var line_start: usize = 0;
    var lines = std.mem.splitScalar(u8, page.markdown, '\n');
    while (lines.next()) |line| {
        defer line_start += line.len + 1;
        if (std.mem.startsWith(u8, line, "#")) {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            const title = std.mem.trimStart(u8, line[level..], " ");
            const id = try slugify(allocator, title);
            if (ids.contains(id)) {
                defer allocator.free(id);
                const loc = markdownLocationAt(page, line_start);
                return failAtHint(page.source_path, loc.line, loc.column, "duplicate heading id '{s}'", .{id}, "Rename one heading so generated heading ids are unique.");
            }
            ids.put(id, {}) catch |err| {
                allocator.free(id);
                return err;
            };
        }
    }
}

const ResolvedLink = struct {
    path: []const u8,
    fragment: []const u8,

    fn deinit(self: ResolvedLink, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

fn validateInternalLinks(allocator: std.mem.Allocator, page: Page, pages: []Page, routes: RouteGraph) !void {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, page.markdown, offset, "](")) |idx| {
        const destination_start = idx + 2;
        const rest = page.markdown[destination_start..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const destination = markdownLinkDestination(rest[0..end]);
        if (try resolveInternalLink(allocator, page.url, destination)) |link| {
            defer link.deinit(allocator);
            const loc = markdownLocationAt(page, destination_start);
            const route = findRouteForLink(routes, link.path) orelse return failAtHint(page.source_path, loc.line, loc.column, "broken internal link '{s}'", .{destination}, "Create the target page/static file or update the link destination.");
            if (link.fragment.len > 0 and (route.kind == .page or route.kind == .post)) {
                const target = findPageByUrl(pages, route.url) orelse return failAtHint(page.source_path, loc.line, loc.column, "broken internal link '{s}'", .{destination}, "Create the target page or update the link destination.");
                if (!htmlHasId(target.html, link.fragment)) return failAtHint(page.source_path, loc.line, loc.column, "broken internal anchor '{s}'", .{destination}, "Add a heading that generates this id, or update the fragment.");
            } else if (link.fragment.len > 0) {
                return failAtHint(page.source_path, loc.line, loc.column, "broken internal anchor '{s}'", .{destination}, "Fragments can only be validated against generated page and post HTML.");
            }
        }
        offset = destination_start + end + 1;
    }
}

fn markdownLocationAt(page: Page, index: usize) SourceLocation {
    const loc = sourceLocationAt(page.markdown, index);
    return .{ .line = page.body_line + loc.line - 1, .column = loc.column };
}

fn markdownLinkDestination(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == '<') {
        if (std.mem.indexOfScalar(u8, trimmed, '>')) |end| return std.mem.trim(u8, trimmed[1..end], " \t\r\n");
    }
    var end: usize = 0;
    while (end < trimmed.len and !std.ascii.isWhitespace(trimmed[end])) end += 1;
    return trimmed[0..end];
}

fn resolveInternalLink(allocator: std.mem.Allocator, page_url: []const u8, destination: []const u8) !?ResolvedLink {
    if (destination.len == 0 or std.mem.startsWith(u8, destination, "//") or hasUrlScheme(destination)) return null;

    var without_fragment = destination;
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, without_fragment, '#')) |idx| {
        fragment = without_fragment[idx + 1 ..];
        without_fragment = without_fragment[0..idx];
    }
    if (std.mem.indexOfScalar(u8, without_fragment, '?')) |idx| without_fragment = without_fragment[0..idx];

    const path = if (without_fragment.len == 0)
        try allocator.dupe(u8, page_url)
    else if (std.mem.startsWith(u8, without_fragment, "/"))
        try normalizeUrlPath(allocator, without_fragment)
    else
        try resolveRelativeUrlPath(allocator, page_url, without_fragment);

    return .{ .path = path, .fragment = fragment };
}

fn hasUrlScheme(destination: []const u8) bool {
    for (destination, 0..) |c, idx| {
        switch (c) {
            ':' => return idx > 0,
            '/', '?', '#' => return false,
            else => {},
        }
    }
    return false;
}

fn resolveRelativeUrlPath(allocator: std.mem.Allocator, page_url: []const u8, relative: []const u8) ![]const u8 {
    const base = pageBaseUrl(page_url);
    const joined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, relative });
    defer allocator.free(joined);
    return normalizeUrlPath(allocator, joined);
}

fn pageBaseUrl(page_url: []const u8) []const u8 {
    if (std.mem.endsWith(u8, page_url, "/")) return page_url;
    if (std.mem.lastIndexOfScalar(u8, page_url, '/')) |idx| return page_url[0 .. idx + 1];
    return "/";
}

fn normalizeUrlPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var segments = std.array_list.Managed([]const u8).init(allocator);
    defer segments.deinit();

    const trailing_slash = path.len > 1 and std.mem.endsWith(u8, path, "/");
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(segment);
    }

    var out = std.array_list.Managed(u8).init(allocator);
    try out.append('/');
    for (segments.items, 0..) |segment, idx| {
        if (idx > 0) try out.append('/');
        try out.appendSlice(segment);
    }
    if (trailing_slash and out.items.len > 1) try out.append('/');
    return out.toOwnedSlice();
}

fn findRouteForLink(routes: RouteGraph, path: []const u8) ?Route {
    for (routes.routes.items) |route| {
        if (std.mem.eql(u8, route.url, path)) return route;
        if (path.len > 1 and !std.mem.endsWith(u8, path, "/") and !urlPathHasExtension(path) and route.url.len == path.len + 1 and std.mem.startsWith(u8, route.url, path) and route.url[route.url.len - 1] == '/') return route;
    }
    return null;
}

fn findPageByUrl(pages: []Page, url: []const u8) ?Page {
    for (pages) |page| {
        if (std.mem.eql(u8, page.url, url)) return page;
    }
    return null;
}

fn urlPathHasExtension(path: []const u8) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| idx + 1 else 0;
    return std.mem.indexOfScalar(u8, path[start..], '.') != null;
}

fn htmlHasId(html: []const u8, id: []const u8) bool {
    return htmlHasQuotedId(html, id, "\"") or htmlHasQuotedId(html, id, "'");
}

fn htmlHasQuotedId(html: []const u8, id: []const u8, comptime quote: []const u8) bool {
    const needle = " id=" ++ quote;
    var rest = html;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        const start = idx + needle.len;
        const value = rest[start..];
        const end = std.mem.indexOf(u8, value, quote) orelse return false;
        if (std.mem.eql(u8, value[0..end], id)) return true;
        rest = value[end + quote.len ..];
    }
    return false;
}

fn buildRouteGraph(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig, pages: []Page) !RouteGraph {
    var graph = RouteGraph.init(allocator);
    errdefer graph.deinit();
    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    defer allocator.free(out_dir);

    for (pages) |page| {
        if (page.fm.draft) continue;
        const rel = try outputRelForUrl(allocator, page.url);
        defer allocator.free(rel);
        try graph.add(.{
            .kind = if (page.is_post) .post else .page,
            .source_path = page.source_path,
            .url = page.url,
            .out_path = try graph.own(try join(allocator, &.{ out_dir, rel })),
        });
    }

    var seen_tags = std.StringHashMap(void).init(allocator);
    defer seen_tags.deinit();
    for (pages) |page| {
        if (!page.is_post or page.fm.draft) continue;
        for (page.fm.tags) |tag| {
            const slug = try slugify(allocator, tag);
            if (seen_tags.contains(slug)) {
                allocator.free(slug);
                continue;
            }
            seen_tags.put(slug, {}) catch |err| {
                allocator.free(slug);
                return err;
            };
            const owned_slug = try graph.own(slug);
            try graph.add(.{
                .kind = .tag,
                .url = try graph.own(try std.fmt.allocPrint(allocator, "/tags/{s}/", .{owned_slug})),
                .out_path = try graph.own(try join(allocator, &.{ out_dir, "tags", owned_slug, "index.html" })),
            });
        }
    }

    try graph.add(.{ .kind = .archive, .url = "/archive/", .out_path = try graph.own(try join(allocator, &.{ out_dir, "archive", "index.html" })) });
    try graph.add(.{ .kind = .rss, .url = "/rss.xml", .out_path = try graph.own(try join(allocator, &.{ out_dir, "rss.xml" })) });
    try graph.add(.{ .kind = .sitemap, .url = "/sitemap.xml", .out_path = try graph.own(try join(allocator, &.{ out_dir, "sitemap.xml" })) });

    const static_dir = try join(allocator, &.{ dir, "static" });
    defer allocator.free(static_dir);
    try addStaticRoutes(allocator, &graph, static_dir, out_dir, "");

    return graph;
}

fn addStaticRoutes(allocator: std.mem.Allocator, graph: *RouteGraph, static_dir: []const u8, out_dir: []const u8, rel_dir: []const u8) !void {
    const current_dir = if (rel_dir.len == 0) try allocator.dupe(u8, static_dir) else try join(allocator, &.{ static_dir, rel_dir });
    defer allocator.free(current_dir);

    var d = std.Io.Dir.cwd().openDir(runtime_io, current_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer d.close(runtime_io);

    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, entry.name });
        defer allocator.free(rel_path);

        switch (entry.kind) {
            .file => try graph.add(.{
                .kind = .static_asset,
                .source_path = try graph.own(try join(allocator, &.{ static_dir, rel_path })),
                .url = try graph.own(try std.fmt.allocPrint(allocator, "/{s}", .{rel_path})),
                .out_path = try graph.own(try join(allocator, &.{ out_dir, rel_path })),
            }),
            .directory => try addStaticRoutes(allocator, graph, static_dir, out_dir, rel_path),
            else => {},
        }
    }
}

fn buildAssetGraph(allocator: std.mem.Allocator, pages: []Page, routes: RouteGraph) !AssetGraph {
    var graph = AssetGraph.init(allocator);
    errdefer graph.deinit();

    for (routes.routes.items) |route| {
        switch (route.kind) {
            .static_asset => try addRouteAsset(allocator, &graph, .site_asset, "", route),
            .page, .post, .tag, .archive, .rss, .sitemap => try addRouteAsset(allocator, &graph, .build_asset, routeOwnerPath(pages, route), route),
        }
    }

    for (pages) |page| {
        if (page.fm.draft) continue;
        try addPageReferencedAssets(allocator, &graph, page, routes);
    }

    return graph;
}

fn addRouteAsset(allocator: std.mem.Allocator, graph: *AssetGraph, kind: AssetKind, owner_path: []const u8, route: Route) !void {
    try graph.add(.{
        .kind = kind,
        .owner_path = try assetOwnCopy(graph, owner_path),
        .source_path = try assetOwnCopy(graph, route.source_path),
        .url = try assetOwnCopy(graph, route.url),
        .out_path = try assetOwnCopy(graph, route.out_path),
        .dimensions = if (kind == .site_asset) try probeImageDimensionsFromFile(allocator, route.source_path) else null,
    });
}

fn addPageReferencedAssets(allocator: std.mem.Allocator, graph: *AssetGraph, page: Page, routes: RouteGraph) !void {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, page.markdown, offset, "](")) |idx| {
        const destination_start = idx + 2;
        const rest = page.markdown[destination_start..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const destination = markdownLinkDestination(rest[0..end]);
        if (try resolveInternalLink(allocator, page.url, destination)) |link| {
            defer link.deinit(allocator);
            if (urlPathHasExtension(link.path)) {
                if (findRouteForLink(routes, link.path)) |route| {
                    if (route.kind == .static_asset) try graph.add(.{
                        .kind = .page_asset,
                        .owner_path = try assetOwnCopy(graph, page.source_path),
                        .source_path = try assetOwnCopy(graph, route.source_path),
                        .url = try assetOwnCopy(graph, route.url),
                        .out_path = try assetOwnCopy(graph, route.out_path),
                        .dimensions = try probeImageDimensionsFromFile(allocator, route.source_path),
                    });
                }
            }
        }
        offset = destination_start + end + 1;
    }
}

fn routeOwnerPath(pages: []Page, route: Route) []const u8 {
    if (route.kind != .page and route.kind != .post) return "";
    const page = findPageByUrl(pages, route.url) orelse return "";
    return page.source_path;
}

fn assetOwnCopy(graph: *AssetGraph, value: []const u8) ![]const u8 {
    return graph.own(try graph.allocator.dupe(u8, value));
}

fn probeImageDimensionsFromFile(allocator: std.mem.Allocator, path: []const u8) !?ImageDimensions {
    if (!isSupportedImagePath(path)) return null;
    const data = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);
    return probeImageDimensions(data);
}

fn isSupportedImagePath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".png") or
        endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".gif");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn probeImageDimensions(data: []const u8) ?ImageDimensions {
    if (probePngDimensions(data)) |dimensions| return dimensions;
    if (probeGifDimensions(data)) |dimensions| return dimensions;
    if (probeJpegDimensions(data)) |dimensions| return dimensions;
    return null;
}

fn probePngDimensions(data: []const u8) ?ImageDimensions {
    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], &png_signature)) return null;
    if (!std.mem.eql(u8, data[12..16], "IHDR")) return null;
    return .{
        .width = readU32Be(data, 16),
        .height = readU32Be(data, 20),
    };
}

fn probeGifDimensions(data: []const u8) ?ImageDimensions {
    if (data.len < 10) return null;
    if (!std.mem.startsWith(u8, data, "GIF87a") and !std.mem.startsWith(u8, data, "GIF89a")) return null;
    return .{
        .width = readU16Le(data, 6),
        .height = readU16Le(data, 8),
    };
}

fn probeJpegDimensions(data: []const u8) ?ImageDimensions {
    if (data.len < 4 or data[0] != 0xff or data[1] != 0xd8) return null;
    var i: usize = 2;
    while (i + 3 < data.len) {
        while (i < data.len and data[i] != 0xff) i += 1;
        while (i < data.len and data[i] == 0xff) i += 1;
        if (i >= data.len) return null;
        const marker = data[i];
        i += 1;
        if (marker == 0xd9 or marker == 0xda) return null;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (i + 2 > data.len) return null;
        const segment_len = readU16Be(data, i);
        if (segment_len < 2 or i + segment_len > data.len) return null;
        if (isJpegStartOfFrame(marker)) {
            if (segment_len < 7) return null;
            return .{
                .height = readU16Be(data, i + 3),
                .width = readU16Be(data, i + 5),
            };
        }
        i += segment_len;
    }
    return null;
}

fn readU16Be(data: []const u8, index: usize) u16 {
    return (@as(u16, data[index]) << 8) | data[index + 1];
}

fn readU16Le(data: []const u8, index: usize) u16 {
    return @as(u16, data[index]) | (@as(u16, data[index + 1]) << 8);
}

fn readU32Be(data: []const u8, index: usize) u32 {
    return (@as(u32, data[index]) << 24) |
        (@as(u32, data[index + 1]) << 16) |
        (@as(u32, data[index + 2]) << 8) |
        data[index + 3];
}

fn isJpegStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
        else => false,
    };
}

fn outputRelForUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (std.mem.eql(u8, url, "/")) return allocator.dupe(u8, "index.html");
    if (std.mem.endsWith(u8, url, ".xml") or std.mem.endsWith(u8, url, ".json")) return allocator.dupe(u8, std.mem.trimStart(u8, url, "/"));
    return std.fmt.allocPrint(allocator, "{s}index.html", .{std.mem.trimStart(u8, url, "/")});
}

fn findPageRoute(routes: RouteGraph, url: []const u8) ?Route {
    for (routes.routes.items) |route| {
        if ((route.kind == .page or route.kind == .post) and std.mem.eql(u8, route.url, url)) return route;
    }
    return null;
}

fn findRoute(routes: RouteGraph, kind: RouteKind, url: []const u8) ?Route {
    for (routes.routes.items) |route| {
        if (route.kind == kind and std.mem.eql(u8, route.url, url)) return route;
    }
    return null;
}

fn copySiteAssets(allocator: std.mem.Allocator, assets: AssetGraph) !void {
    for (assets.assets.items) |asset| {
        if (asset.kind != .site_asset) continue;
        const data = try std.Io.Dir.cwd().readFileAlloc(runtime_io, asset.source_path, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(data);
        try writeAll(allocator, asset.out_path, data);
    }
}

const TemplateContext = struct {
    site: SiteConfig,
    page: Page,
    content: []const u8,
    post_list: []const u8,
    head: []const u8,
    runtime: []const u8,
    page_tags: []const u8,
    page_full_title: []const u8,
};

const TemplateAction = enum { none, replace, text, html, attr_only };

const ClosingTag = struct {
    start: usize,
    end: usize,
};

const HtmlOpenTag = struct {
    name: []const u8,
    line: usize,
    column: usize,
};

const SourceLocation = struct {
    line: usize,
    column: usize,
};

fn renderLayout(allocator: std.mem.Allocator, layout: []const u8, layout_path: []const u8, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8) ![]const u8 {
    const page_tags = try renderTagsInline(allocator, page.fm.tags);
    defer allocator.free(page_tags);
    const page_full_title = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ page.fm.title, site.title });
    defer allocator.free(page_full_title);
    const rendered = try renderTemplate(allocator, layout, layout_path, .{
        .site = site,
        .page = page,
        .content = content,
        .post_list = post_list,
        .head = head,
        .runtime = runtime,
        .page_tags = page_tags,
        .page_full_title = page_full_title,
    });
    defer allocator.free(rendered);
    return applyTransitionNames(allocator, rendered);
}

fn renderTemplate(allocator: std.mem.Allocator, layout: []const u8, layout_path: []const u8, ctx: TemplateContext) ![]const u8 {
    if (std.mem.indexOf(u8, layout, "{{")) |idx| {
        const loc = sourceLocationAt(layout, idx);
        try failAtHint(layout_path, loc.line, loc.column, "legacy template token found", .{}, "Replace {{...}} with z-text, z-html, z-replace, or z-attr:* attributes.");
        unreachable;
    }
    try validateTemplateStructure(allocator, layout, layout_path);

    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, layout, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, layout, lt, '>') orelse {
            const loc = sourceLocationAt(layout, lt);
            try failAtHint(layout_path, loc.line, loc.column, "unterminated template tag", .{}, "Close the tag with >.");
            unreachable;
        };
        const loc = sourceLocationAt(layout, lt);
        const tag = layout[lt .. gt + 1];
        const name = startTagName(tag) orelse {
            try out.appendSlice(layout[i .. gt + 1]);
            i = gt + 1;
            continue;
        };
        const action = templateAction(tag);
        if (action == .none) {
            try out.appendSlice(layout[i .. gt + 1]);
            i = gt + 1;
            continue;
        }

        try out.appendSlice(layout[i..lt]);
        if (action == .replace) {
            const expr = templateAttrValue(tag, "z-replace") orelse {
                try failAtHint(layout_path, loc.line, loc.column, "missing z-replace value on <{s}>", .{name}, "Set z-replace to a supported binding such as content.");
                unreachable;
            };
            const close = findClosingTag(layout, gt + 1, name) orelse {
                try failAtHint(layout_path, loc.line, loc.column, "missing closing tag for <{s}>", .{name}, "Add the matching closing tag after the replace target.");
                unreachable;
            };
            try out.appendSlice(try templateValue(ctx, expr, layout_path, loc));
            i = close.end;
            continue;
        }

        const close = if (action == .text or action == .html)
            findClosingTag(layout, gt + 1, name) orelse {
                try failAtHint(layout_path, loc.line, loc.column, "missing closing tag for <{s}>", .{name}, "Add the matching closing tag around the template slot.");
                unreachable;
            }
        else
            null;

        const rendered_tag = try renderTemplateStartTag(allocator, tag, ctx, layout_path, loc);
        defer allocator.free(rendered_tag);
        try out.appendSlice(rendered_tag);

        if (action == .text or action == .html) {
            const expr = if (action == .text) templateAttrValue(tag, "z-text") orelse {
                try failAtHint(layout_path, loc.line, loc.column, "missing z-text value on <{s}>", .{name}, "Set z-text to a supported binding such as page.title.");
                unreachable;
            } else templateAttrValue(tag, "z-html") orelse {
                try failAtHint(layout_path, loc.line, loc.column, "missing z-html value on <{s}>", .{name}, "Set z-html to a supported binding such as content.");
                unreachable;
            };
            const value = try templateValue(ctx, expr, layout_path, loc);
            if (action == .text) {
                try appendEscaped(&out, value);
            } else {
                try out.appendSlice(value);
            }
            try out.appendSlice(layout[close.?.start..close.?.end]);
            i = close.?.end;
        } else {
            i = gt + 1;
        }
    }
    try out.appendSlice(layout[i..]);
    return out.toOwnedSlice();
}

fn templateAction(tag: []const u8) TemplateAction {
    if (templateAttrValue(tag, "z-replace") != null) return .replace;
    if (templateAttrValue(tag, "z-text") != null) return .text;
    if (templateAttrValue(tag, "z-html") != null) return .html;
    if (std.mem.indexOf(u8, tag, "z-attr:") != null) return .attr_only;
    return .none;
}

fn templateValue(ctx: TemplateContext, expr: []const u8, layout_path: []const u8, loc: SourceLocation) ![]const u8 {
    const name = std.mem.trim(u8, expr, " \t\r\n");
    if (std.mem.eql(u8, name, "site.title")) return ctx.site.title;
    if (std.mem.eql(u8, name, "site.url")) return ctx.site.url;
    if (std.mem.eql(u8, name, "site.language")) return ctx.site.language;
    if (std.mem.eql(u8, name, "site.timezone")) return ctx.site.timezone;
    if (std.mem.eql(u8, name, "site.author")) return ctx.site.author;
    if (std.mem.eql(u8, name, "page.title")) return ctx.page.fm.title;
    if (std.mem.eql(u8, name, "page.full_title")) return ctx.page_full_title;
    if (std.mem.eql(u8, name, "page.date")) return ctx.page.fm.date;
    if (std.mem.eql(u8, name, "page.transition")) return ctx.page.fm.transition;
    if (std.mem.eql(u8, name, "page.tags")) return ctx.page_tags;
    if (std.mem.eql(u8, name, "content")) return ctx.content;
    if (std.mem.eql(u8, name, "post_list")) return ctx.post_list;
    if (std.mem.eql(u8, name, "zlog.head")) return ctx.head;
    if (std.mem.eql(u8, name, "zlog.runtime")) return ctx.runtime;
    try failAtHint(layout_path, loc.line, loc.column, "unknown template binding '{s}'", .{name}, "Use a supported binding such as page.title, content, or zlog.head.");
    unreachable;
}

fn renderTemplateStartTag(allocator: std.mem.Allocator, tag: []const u8, ctx: TemplateContext, layout_path: []const u8, loc: SourceLocation) ![]const u8 {
    const name = startTagName(tag) orelse return allocator.dupe(u8, tag);
    var out = std.array_list.Managed(u8).init(allocator);
    try out.append('<');
    try out.appendSlice(name);

    var i: usize = 1 + name.len;
    while (i < tag.len and tag[i] != '>' and tag[i] != '/') {
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] == '>' or tag[i] == '/') break;
        const attr_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != '>' and tag[i] != '/' and !std.ascii.isWhitespace(tag[i])) i += 1;
        const attr_name = tag[attr_start..i];
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i < tag.len and tag[i] == '=') {
            i += 1;
            while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
            if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
                const quote = tag[i];
                i += 1;
                while (i < tag.len and tag[i] != quote) i += 1;
                if (i < tag.len) i += 1;
            } else {
                while (i < tag.len and tag[i] != '>' and tag[i] != '/' and !std.ascii.isWhitespace(tag[i])) i += 1;
            }
        }
        const attr = tag[attr_start..i];
        if (std.mem.eql(u8, attr_name, "z-text") or std.mem.eql(u8, attr_name, "z-html") or std.mem.eql(u8, attr_name, "z-replace")) continue;
        if (std.mem.startsWith(u8, attr_name, "z-attr:")) {
            const value = templateAttrValue(tag, attr_name) orelse "";
            const rendered = try templateValue(ctx, value, layout_path, loc);
            if (rendered.len == 0) continue;
            try out.append(' ');
            try out.appendSlice(attr_name["z-attr:".len..]);
            try out.appendSlice("=\"");
            try appendEscaped(&out, rendered);
            try out.append('"');
            continue;
        }
        try out.append(' ');
        try out.appendSlice(attr);
    }

    if (isSelfClosingTag(tag)) {
        try out.appendSlice(" />");
    } else {
        try out.append('>');
    }
    return out.toOwnedSlice();
}

fn templateAttrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < tag.len and tag[i] != '>' and tag[i] != '/') {
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        const attr_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != '>' and tag[i] != '/' and !std.ascii.isWhitespace(tag[i])) i += 1;
        const attr_name = tag[attr_start..i];
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len) return null;
        const value: []const u8 = if (tag[i] == '"' or tag[i] == '\'') value: {
            const quote = tag[i];
            i += 1;
            const value_start = i;
            while (i < tag.len and tag[i] != quote) i += 1;
            const value_end = i;
            if (i < tag.len) i += 1;
            break :value tag[value_start..value_end];
        } else value: {
            const value_start = i;
            while (i < tag.len and tag[i] != '>' and tag[i] != '/' and !std.ascii.isWhitespace(tag[i])) i += 1;
            break :value tag[value_start..i];
        };
        if (std.mem.eql(u8, attr_name, name)) return value;
    }
    return null;
}

fn validateTemplateStructure(allocator: std.mem.Allocator, html: []const u8, path: []const u8) !void {
    try validateHtmlDocument(allocator, html, path);
}

fn validateHtmlDocument(allocator: std.mem.Allocator, html: []const u8, path: []const u8) !void {
    var stack = std.array_list.Managed(HtmlOpenTag).init(allocator);
    defer stack.deinit();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            const end = std.mem.indexOf(u8, html[lt + 4 ..], "-->") orelse {
                const loc = sourceLocationAt(html, lt);
                return failAtHint(path, loc.line, loc.column, "unterminated HTML comment", .{}, "Close the comment with -->.");
            };
            i = lt + 4 + end + 3;
            continue;
        }
        const loc = sourceLocationAt(html, lt);
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return failAtHint(path, loc.line, loc.column, "unterminated HTML tag", .{}, "Close the tag with >.");
        const tag = html[lt .. gt + 1];
        if (tag.len >= 2 and (tag[1] == '!' or tag[1] == '?')) {
            i = gt + 1;
            continue;
        }
        if (closingTagName(tag)) |name| {
            if (stack.items.len == 0) return failAtHint(path, loc.line, loc.column, "unexpected closing tag </{s}>", .{name}, "Remove the closing tag or add a matching opening tag.");
            const open = stack.items[stack.items.len - 1];
            if (!std.ascii.eqlIgnoreCase(open.name, name)) return failAtHint(path, loc.line, loc.column, "closing tag </{s}> does not match <{s}> opened at {d}:{d}", .{ name, open.name, open.line, open.column }, "Fix the tag nesting so each closing tag matches the most recent open tag.");
            _ = stack.pop();
        } else if (startTagName(tag)) |name| {
            if (isRawTextHtmlTag(name)) {
                const close = findClosingTag(html, gt + 1, name) orelse return failAtHint(path, loc.line, loc.column, "missing closing tag for <{s}>", .{name}, "Add the matching closing tag.");
                i = close.end;
                continue;
            }
            if (!isSelfClosingTag(tag) and !isVoidHtmlTag(name)) try stack.append(.{ .name = name, .line = loc.line, .column = loc.column });
        }
        i = gt + 1;
    }
    if (stack.items.len > 0) {
        const open = stack.items[stack.items.len - 1];
        return failAtHint(path, open.line, open.column, "unclosed HTML tag <{s}>", .{open.name}, "Add the matching closing tag.");
    }
}

fn sourceLocationAt(text: []const u8, index: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    for (text[0..index]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn startTagName(tag: []const u8) ?[]const u8 {
    if (tag.len < 3 or tag[0] != '<' or tag[1] == '/' or tag[1] == '!' or tag[1] == '?') return null;
    var end: usize = 1;
    while (end < tag.len and tag[end] != '>' and tag[end] != '/' and !std.ascii.isWhitespace(tag[end])) end += 1;
    if (end == 1) return null;
    return tag[1..end];
}

fn closingTagName(tag: []const u8) ?[]const u8 {
    if (tag.len < 4 or !std.mem.startsWith(u8, tag, "</")) return null;
    var end: usize = 2;
    while (end < tag.len and tag[end] != '>' and !std.ascii.isWhitespace(tag[end])) end += 1;
    if (end == 2) return null;
    return tag[2..end];
}

fn isSelfClosingTag(tag: []const u8) bool {
    var i = tag.len;
    while (i > 0 and (tag[i - 1] == '>' or std.ascii.isWhitespace(tag[i - 1]))) i -= 1;
    return i > 0 and tag[i - 1] == '/';
}

fn isVoidHtmlTag(name: []const u8) bool {
    const names = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };
    for (names) |void_name| {
        if (std.ascii.eqlIgnoreCase(name, void_name)) return true;
    }
    return false;
}

fn isRawTextHtmlTag(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style");
}

fn findClosingTag(html: []const u8, start: usize, name: []const u8) ?ClosingTag {
    var i = start;
    var depth: usize = 1;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            const end = std.mem.indexOf(u8, html[lt + 4 ..], "-->") orelse return null;
            i = lt + 4 + end + 3;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return null;
        const tag = html[lt .. gt + 1];
        if (closingTagName(tag)) |close_name| {
            if (std.ascii.eqlIgnoreCase(close_name, name)) {
                depth -= 1;
                if (depth == 0) return .{ .start = lt, .end = gt + 1 };
            }
        } else if (startTagName(tag)) |open_name| {
            if (std.ascii.eqlIgnoreCase(open_name, name) and !isSelfClosingTag(tag) and !isVoidHtmlTag(open_name)) depth += 1;
        }
        i = gt + 1;
    }
    return null;
}

fn renderPostList(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<section class=\"zlog-posts\">\n<h2>Posts</h2>\n<ul>\n");
    for (pages) |p| if (p.is_post and !p.fm.draft) {
        const prefetch = if (p.fm.prefetch.len > 0) p.fm.prefetch else site.prefetch_default;
        try out.print("<li><a href=\"{s}\" data-z-prefetch=\"{s}\"><span style=\"view-transition-name:{s}\">", .{ p.url, prefetch, try safeCssIdent(allocator, if (p.fm.transition.len > 0) p.fm.transition else p.slug) });
        try appendEscaped(&out, p.fm.title);
        try out.print("</span></a> <time>{s}</time></li>\n", .{p.fm.date});
    };
    try out.appendSlice("</ul>\n</section>\n");
    return out.toOwnedSlice();
}

fn renderTagsInline(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(" ");
        const slug = try slugify(allocator, tag);
        defer allocator.free(slug);
        try out.print("<a href=\"/tags/{s}/\" data-z-prefetch=\"hover\">#{s}</a>", .{ slug, tag });
    }
    return out.toOwnedSlice();
}

fn renderHead(allocator: std.mem.Allocator, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(
        \\<style>
        \\@view-transition { navigation: auto; }
        \\@media (prefers-reduced-motion: reduce) { ::view-transition-group(*) { animation-duration: 0.01ms; } }
        \\body { max-width: 72ch; margin: 3rem auto; padding: 0 1rem; font: 16px/1.6 system-ui, sans-serif; }
        \\img { max-width: 100%; height: auto; }
        \\</style>
        \\
    );
    try out.appendSlice("<meta property=\"og:site_name\" content=\"");
    try appendEscaped(&out, site.title);
    try out.appendSlice("\">\n<meta name=\"zlog:timezone\" content=\"");
    try appendEscaped(&out, site.timezone);
    try out.appendSlice("\">\n");
    if (site.author.len > 0) {
        try out.appendSlice("<meta name=\"author\" content=\"");
        try appendEscaped(&out, site.author);
        try out.appendSlice("\">\n");
    }
    if (site.speculation_rules) {
        try out.appendSlice(
            \\<script type="speculationrules">{"prefetch":[{"where":{"selector_matches":"[data-z-prefetch='tap']"},"eagerness":"conservative"},{"where":{"selector_matches":"[data-z-prefetch='hover']"},"eagerness":"moderate"}]}</script>
            \\
        );
    }
    return out.toOwnedSlice();
}

const prefetchRuntime =
    \\<script>
    \\(()=>{const seen=new Set();function ok(a){try{const u=new URL(a.href,location.href);return u.origin===location.origin&&!a.download&&!a.target&&!/[?&](logout|admin|search)=/.test(u.search)&&!seen.has(u.href)}catch{return false}}function pf(a){if(!ok(a))return;seen.add(a.href);const l=document.createElement('link');l.rel='prefetch';l.href=a.href;document.head.appendChild(l)}document.querySelectorAll('a[data-z-prefetch]').forEach(a=>{const m=a.dataset.zPrefetch||'hover';if(m==='false')return;if(m==='load')addEventListener('load',()=>pf(a),{once:true});else if(m==='tap')a.addEventListener('pointerdown',()=>pf(a),{once:true});else if(m==='viewport'&&'IntersectionObserver'in window){const io=new IntersectionObserver(es=>es.forEach(e=>{if(e.isIntersecting){pf(a);io.unobserve(a)}}));io.observe(a)}else{a.addEventListener('pointerenter',()=>pf(a),{once:true});a.addEventListener('focus',()=>pf(a),{once:true})}})})();
    \\</script>
;

fn rewriteNavigationAttributes(allocator: std.mem.Allocator, html: []const u8, default_prefetch: []const u8) ![]const u8 {
    const replacement = try std.fmt.allocPrint(allocator, "data-z-prefetch=\"{s}\">", .{default_prefetch});
    defer allocator.free(replacement);
    return try replaceAll(allocator, html, "data-z-prefetch>", replacement);
}

fn applyImageDimensions(allocator: std.mem.Allocator, html: []const u8, base_url: []const u8, assets: AssetGraph) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse break;
        const tag = html[lt .. gt + 1];
        if (startTagName(tag)) |name| {
            const width_attr = templateAttrValue(tag, "width");
            const height_attr = templateAttrValue(tag, "height");
            if (std.ascii.eqlIgnoreCase(name, "img") and (width_attr == null or height_attr == null)) {
                if (templateAttrValue(tag, "src")) |src| {
                    if (try imageAssetForSrc(allocator, assets, base_url, src)) |asset| {
                        if (asset.dimensions) |dimensions| {
                            const insert_at = imageDimensionInsertOffset(html, lt, gt);
                            try out.appendSlice(html[i..insert_at]);
                            if (width_attr == null) try out.print(" width=\"{d}\"", .{dimensions.width});
                            if (height_attr == null) try out.print(" height=\"{d}\"", .{dimensions.height});
                            try out.appendSlice(html[insert_at .. gt + 1]);
                            i = gt + 1;
                            continue;
                        }
                    }
                }
            }
        }
        try out.appendSlice(html[i .. gt + 1]);
        i = gt + 1;
    }
    try out.appendSlice(html[i..]);
    return out.toOwnedSlice();
}

fn imageAssetForSrc(allocator: std.mem.Allocator, assets: AssetGraph, base_url: []const u8, src: []const u8) !?Asset {
    const link = try resolveInternalLink(allocator, base_url, src) orelse return null;
    defer link.deinit(allocator);
    return assets.firstByKindAndUrl(.site_asset, link.path) orelse assets.firstByKindAndUrl(.page_asset, link.path);
}

fn imageDimensionInsertOffset(html: []const u8, lt: usize, gt: usize) usize {
    var i = gt;
    while (i > lt and std.ascii.isWhitespace(html[i - 1])) i -= 1;
    if (i > lt and html[i - 1] == '/') return i - 1;
    return gt;
}

fn applyTransitionNames(allocator: std.mem.Allocator, html: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var rest = html;
    while (std.mem.indexOf(u8, rest, " z-transition-name=\"")) |idx| {
        try out.appendSlice(rest[0..idx]);
        rest = rest[idx + " z-transition-name=\"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        const name = try safeCssIdent(allocator, rest[0..end]);
        defer allocator.free(name);
        try out.print(" style=\"view-transition-name:{s}\"", .{name});
        rest = rest[end + 1 ..];
    }
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

fn renderTagPages(allocator: std.mem.Allocator, routes: RouteGraph, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |tag_slug| allocator.free(tag_slug.*);
        seen.deinit();
    }

    for (pages) |p| {
        if (!p.is_post or p.fm.draft) continue;
        for (p.fm.tags) |tag| {
            const tag_slug = try slugify(allocator, tag);
            if (seen.contains(tag_slug)) {
                allocator.free(tag_slug);
                continue;
            }
            seen.put(tag_slug, {}) catch |err| {
                allocator.free(tag_slug);
                return err;
            };
            const tag_url = try std.fmt.allocPrint(allocator, "/tags/{s}/", .{tag_slug});
            defer allocator.free(tag_url);
            const route = findRoute(routes, .tag, tag_url) orelse return fail("missing tag route for {s}", .{tag_url});
            const rendered = try renderTagPageHtml(allocator, tag, tag_slug, pages, site, head, runtime);
            defer allocator.free(rendered);
            try validateHtmlDocument(allocator, rendered, route.out_path);
            try writeAll(allocator, route.out_path, rendered);
        }
    }
}

fn renderTagPageHtml(allocator: std.mem.Allocator, tag: []const u8, tag_slug: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) ![]const u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    try body.print("<h1>#{s}</h1>\n<ul>\n", .{tag});
    for (pages) |q| if (q.is_post and !q.fm.draft and hasTag(q, tag)) {
        try body.print("<li><a href=\"{s}\" data-z-prefetch=\"hover\">{s}</a></li>\n", .{ q.url, q.fm.title });
    };
    try body.appendSlice("</ul>");
    const body_html = try body.toOwnedSlice();
    defer allocator.free(body_html);

    const fake = Page{ .source_path = "", .slug = tag_slug, .url = "", .fm = .{ .title = tag, .layout = "base.shtml" }, .markdown = "", .html = "", .is_post = false };
    return renderLayout(allocator, initBaseLayout, "<builtin base layout>", site, fake, body_html, "", head, runtime);
}

fn renderArchivePage(allocator: std.mem.Allocator, routes: RouteGraph, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) !void {
    const rendered = try renderArchivePageHtml(allocator, pages, site, head, runtime);
    defer allocator.free(rendered);
    const route = routes.firstByKind(.archive) orelse return fail("missing archive route", .{});
    try validateHtmlDocument(allocator, rendered, route.out_path);
    try writeAll(allocator, route.out_path, rendered);
}

fn renderArchivePageHtml(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) ![]const u8 {
    var body = std.array_list.Managed(u8).init(allocator);
    try body.appendSlice("<h1>Archive</h1>\n<ul>\n");
    for (pages) |p| if (p.is_post and !p.fm.draft) try body.print("<li><time>{s}</time> <a href=\"{s}\" data-z-prefetch=\"hover\">{s}</a></li>\n", .{ p.fm.date, p.url, p.fm.title });
    try body.appendSlice("</ul>");
    const body_html = try body.toOwnedSlice();
    defer allocator.free(body_html);

    const fake = Page{ .source_path = "", .slug = "archive", .url = "/archive/", .fm = .{ .title = "Archive", .layout = "base.shtml" }, .markdown = "", .html = "", .is_post = false };
    return renderLayout(allocator, initBaseLayout, "<builtin base layout>", site, fake, body_html, "", head, runtime);
}

fn renderRss(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    const site_url = try absoluteSiteUrl(allocator, site, "/");
    defer allocator.free(site_url);
    const feed_url = try absoluteSiteUrl(allocator, site, "/rss.xml");
    defer allocator.free(feed_url);

    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<channel>\n<title>");
    try appendXmlEscaped(&out, site.title);
    try out.appendSlice("</title>\n<link>");
    try appendXmlEscaped(&out, site_url);
    try out.appendSlice("</link>\n<description>");
    try appendXmlEscaped(&out, site.title);
    try out.appendSlice("</description>\n<language>");
    try appendXmlEscaped(&out, site.language);
    try out.appendSlice("</language>\n");
    if (site.author.len > 0) {
        try out.appendSlice("<dc:creator>");
        try appendXmlEscaped(&out, site.author);
        try out.appendSlice("</dc:creator>\n");
    }
    try out.appendSlice("<atom:link href=\"");
    try appendXmlEscaped(&out, feed_url);
    try out.appendSlice("\" rel=\"self\" type=\"application/rss+xml\" />\n");
    if (latestRssTimestamp(pages)) |latest| {
        const latest_date = try formatRssDate(allocator, latest, site.timezone);
        defer allocator.free(latest_date);
        try out.appendSlice("<lastBuildDate>");
        try appendXmlEscaped(&out, latest_date);
        try out.appendSlice("</lastBuildDate>\n");
    }
    for (pages) |p| if (p.is_post and !p.fm.draft) {
        const item_url = try absoluteSiteUrl(allocator, site, p.url);
        defer allocator.free(item_url);
        const pub_date = try formatRssDate(allocator, p.fm.date, site.timezone);
        defer allocator.free(pub_date);
        try out.appendSlice("<item>\n<title>");
        try appendXmlEscaped(&out, p.fm.title);
        try out.appendSlice("</title>\n<link>");
        try appendXmlEscaped(&out, item_url);
        try out.appendSlice("</link>\n<guid isPermaLink=\"true\">");
        try appendXmlEscaped(&out, item_url);
        try out.appendSlice("</guid>\n<pubDate>");
        try appendXmlEscaped(&out, pub_date);
        try out.appendSlice("</pubDate>\n");
        if (site.author.len > 0) {
            try out.appendSlice("<dc:creator>");
            try appendXmlEscaped(&out, site.author);
            try out.appendSlice("</dc:creator>\n");
        }
        if (p.fm.updated.len > 0) {
            try out.appendSlice("<dc:date>");
            try appendXmlEscaped(&out, p.fm.updated);
            try out.appendSlice("</dc:date>\n");
        }
        try out.appendSlice("<description>");
        try appendXmlEscaped(&out, p.html);
        try out.appendSlice("</description>\n</item>\n");
    };
    try out.appendSlice("</channel></rss>\n");
    return out.toOwnedSlice();
}

fn absoluteSiteUrl(allocator: std.mem.Allocator, site: SiteConfig, path: []const u8) ![]const u8 {
    if (hasUrlScheme(path)) return allocator.dupe(u8, path);
    const base = std.mem.trimEnd(u8, site.url, "/");
    if (std.mem.startsWith(u8, path, "/")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, path });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

fn latestRssTimestamp(pages: []Page) ?[]const u8 {
    var latest: ?[]const u8 = null;
    for (pages) |p| {
        if (!p.is_post or p.fm.draft) continue;
        const timestamp = if (p.fm.updated.len > 0) p.fm.updated else p.fm.date;
        if (timestamp.len == 0) continue;
        if (latest == null or std.mem.order(u8, timestamp, latest.?) == .gt) latest = timestamp;
    }
    return latest;
}

const RssTimestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    zone: [5]u8 = .{ '+', '0', '0', '0', '0' },
};

const rss_weekdays = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const rss_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn formatRssDate(allocator: std.mem.Allocator, timestamp: []const u8, timezone: []const u8) ![]const u8 {
    const parsed = parseIsoTimestampWithTimezone(timestamp, timezone) orelse return allocator.dupe(u8, timestamp);
    return std.fmt.allocPrint(
        allocator,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} {s}",
        .{
            rss_weekdays[weekdayIndex(parsed.year, parsed.month, parsed.day)],
            parsed.day,
            rss_months[parsed.month - 1],
            parsed.year,
            parsed.hour,
            parsed.minute,
            parsed.second,
            parsed.zone[0..],
        },
    );
}

fn parseIsoTimestamp(timestamp: []const u8) ?RssTimestamp {
    return parseIsoTimestampWithTimezone(timestamp, "UTC");
}

fn parseIsoTimestampWithTimezone(timestamp: []const u8, timezone: []const u8) ?RssTimestamp {
    if (timestamp.len < 10) return null;
    if (timestamp[4] != '-' or timestamp[7] != '-') return null;
    var parsed = RssTimestamp{
        .year = parseFixedInt(u16, timestamp[0..4]) catch return null,
        .month = parseFixedInt(u8, timestamp[5..7]) catch return null,
        .day = parseFixedInt(u8, timestamp[8..10]) catch return null,
        .zone = rssTimezoneOffset(timezone),
    };
    if (!validDate(parsed.year, parsed.month, parsed.day)) return null;
    if (timestamp.len == 10) return parsed;
    if (timestamp[10] != 'T' and timestamp[10] != ' ') return null;
    if (timestamp.len < 19) return null;
    if (timestamp[13] != ':' or timestamp[16] != ':') return null;
    parsed.hour = parseFixedInt(u8, timestamp[11..13]) catch return null;
    parsed.minute = parseFixedInt(u8, timestamp[14..16]) catch return null;
    parsed.second = parseFixedInt(u8, timestamp[17..19]) catch return null;
    if (parsed.hour > 23 or parsed.minute > 59 or parsed.second > 60) return null;

    var cursor: usize = 19;
    if (cursor < timestamp.len and timestamp[cursor] == '.') {
        cursor += 1;
        const start = cursor;
        while (cursor < timestamp.len and std.ascii.isDigit(timestamp[cursor])) cursor += 1;
        if (cursor == start) return null;
    }
    if (cursor == timestamp.len) return parsed;
    if (timestamp[cursor] == 'Z' and cursor + 1 == timestamp.len) return parsed;
    if ((timestamp[cursor] == '+' or timestamp[cursor] == '-') and timestamp.len == cursor + 6 and timestamp[cursor + 3] == ':') {
        const offset_hour = parseFixedInt(u8, timestamp[cursor + 1 .. cursor + 3]) catch return null;
        const offset_minute = parseFixedInt(u8, timestamp[cursor + 4 .. cursor + 6]) catch return null;
        if (offset_hour > 23 or offset_minute > 59) return null;
        parsed.zone = .{ timestamp[cursor], timestamp[cursor + 1], timestamp[cursor + 2], timestamp[cursor + 4], timestamp[cursor + 5] };
        return parsed;
    }
    return null;
}

fn rssTimezoneOffset(timezone: []const u8) [5]u8 {
    if (std.mem.eql(u8, timezone, "UTC")) return .{ '+', '0', '0', '0', '0' };
    return parseTimezoneOffset(timezone) orelse .{ '+', '0', '0', '0', '0' };
}

fn parseTimezoneOffset(timezone: []const u8) ?[5]u8 {
    if (timezone.len != 6) return null;
    if (timezone[0] != '+' and timezone[0] != '-') return null;
    if (timezone[3] != ':') return null;
    const hour = parseFixedInt(u8, timezone[1..3]) catch return null;
    const minute = parseFixedInt(u8, timezone[4..6]) catch return null;
    if (hour > 23 or minute > 59) return null;
    return .{ timezone[0], timezone[1], timezone[2], timezone[4], timezone[5] };
}

fn parseFixedInt(comptime T: type, digits: []const u8) !T {
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidCharacter;
    return std.fmt.parseInt(T, digits, 10);
}

fn validDate(year: u16, month: u8, day: u8) bool {
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    return day <= daysInMonth(year, month);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn weekdayIndex(year: u16, month: u8, day: u8) usize {
    const offsets = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    var y: i32 = @intCast(year);
    const m: usize = @intCast(month);
    if (m < 3) y -= 1;
    const w = @mod(y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + offsets[m - 1] + @as(i32, @intCast(day)), 7);
    return @intCast(w);
}

fn renderSitemap(allocator: std.mem.Allocator, routes: RouteGraph, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (routes.routes.items) |route| {
        if (!includeInSitemap(route)) continue;
        if (route.kind == .page or route.kind == .post) {
            if (findPageByUrl(pages, route.url)) |page| {
                if (page.fm.draft) continue;
            } else continue;
        }
        const loc = try absoluteSiteUrl(allocator, site, route.url);
        defer allocator.free(loc);
        try out.appendSlice("<url>\n<loc>");
        try appendXmlEscaped(&out, loc);
        try out.appendSlice("</loc>\n");
        if (try sitemapLastmod(allocator, route, pages)) |lastmod| {
            try out.appendSlice("<lastmod>");
            try appendXmlEscaped(&out, lastmod);
            try out.appendSlice("</lastmod>\n");
        }
        try out.appendSlice("</url>\n");
    }
    try out.appendSlice("</urlset>\n");
    return out.toOwnedSlice();
}

fn includeInSitemap(route: Route) bool {
    return switch (route.kind) {
        .page, .post, .tag, .archive => true,
        .rss, .sitemap, .static_asset => false,
    };
}

fn sitemapLastmod(allocator: std.mem.Allocator, route: Route, pages: []Page) !?[]const u8 {
    return switch (route.kind) {
        .page, .post => if (findPageByUrl(pages, route.url)) |page| reliablePageTimestamp(page) else null,
        .archive => latestReliableTimestamp(pages),
        .tag => try latestReliableTimestampForTagRoute(allocator, route.url, pages),
        .rss, .sitemap, .static_asset => null,
    };
}

fn reliablePageTimestamp(page: Page) ?[]const u8 {
    const timestamp = if (page.fm.updated.len > 0) page.fm.updated else page.fm.date;
    if (timestamp.len == 0 or parseIsoTimestamp(timestamp) == null) return null;
    return timestamp;
}

fn latestReliableTimestamp(pages: []Page) ?[]const u8 {
    var latest: ?[]const u8 = null;
    for (pages) |page| {
        if (!page.is_post or page.fm.draft) continue;
        updateLatestTimestamp(&latest, reliablePageTimestamp(page));
    }
    return latest;
}

fn latestReliableTimestampForTagRoute(allocator: std.mem.Allocator, route_url: []const u8, pages: []Page) !?[]const u8 {
    const route_slug = tagSlugFromRoute(route_url) orelse return null;
    var latest: ?[]const u8 = null;
    for (pages) |page| {
        if (!page.is_post or page.fm.draft) continue;
        if (!try pageHasTagSlug(allocator, page, route_slug)) continue;
        updateLatestTimestamp(&latest, reliablePageTimestamp(page));
    }
    return latest;
}

fn tagSlugFromRoute(route_url: []const u8) ?[]const u8 {
    const prefix = "/tags/";
    if (!std.mem.startsWith(u8, route_url, prefix) or !std.mem.endsWith(u8, route_url, "/")) return null;
    if (route_url.len <= prefix.len + 1) return null;
    return route_url[prefix.len .. route_url.len - 1];
}

fn pageHasTagSlug(allocator: std.mem.Allocator, page: Page, route_slug: []const u8) !bool {
    for (page.fm.tags) |tag| {
        const slug = try slugify(allocator, tag);
        defer allocator.free(slug);
        if (std.mem.eql(u8, slug, route_slug)) return true;
    }
    return false;
}

fn updateLatestTimestamp(latest: *?[]const u8, candidate: ?[]const u8) void {
    const timestamp = candidate orelse return;
    if (latest.* == null or std.mem.order(u8, timestamp, latest.*.?) == .gt) latest.* = timestamp;
}

fn countPublishedPages(pages: []Page) usize {
    var count: usize = 0;
    for (pages) |page| {
        if (!page.fm.draft) count += 1;
    }
    return count;
}

fn hasTag(page: Page, tag: []const u8) bool {
    for (page.fm.tags) |t| if (std.mem.eql(u8, t, tag)) return true;
    return false;
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

fn appendXmlEscaped(out: *std.array_list.Managed(u8), text: []const u8) !void {
    try appendEscaped(out, text);
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

const initConfig =
    \\.title = "example.dev",
    \\.url = "https://example.dev",
    \\.language = "en",
    \\.timezone = "UTC",
    \\.author = "Example Author",
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
    \\<html z-attr:lang="site.language"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title z-text="page.full_title"></title><template z-replace="zlog.head"></template></head>
    \\<body><header><a href="/" data-z-prefetch="hover" z-text="site.title"></a></header><main><template z-replace="content"></template><template z-replace="post_list"></template></main><template z-replace="zlog.runtime"></template></body></html>
;
const initPostLayout =
    \\<!doctype html>
    \\<html z-attr:lang="site.language"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title z-text="page.full_title"></title><template z-replace="zlog.head"></template></head>
    \\<body><header><a href="/" data-z-prefetch="hover" z-text="site.title"></a></header><article><h1 z-text="page.title" z-attr:z-transition-name="page.transition"></h1><p><time z-text="page.date"></time> <span z-replace="page.tags"></span></p><template z-replace="content"></template></article><template z-replace="zlog.runtime"></template></body></html>
;

test "site config reads metadata fields and renders head metadata" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "site/zlog.ziggy",
        .data =
        \\.title = "Example",
        \\.url = "https://example.com",
        \\.language = "en-US",
        \\.timezone = "+09:00",
        \\.author = "Example Author",
        \\.speculation_rules = false,
        ,
    });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const root = try std.fmt.allocPrint(arena_allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    const site = try loadSite(arena_allocator, root);
    try std.testing.expectEqualStrings("https://example.com", site.url);
    try std.testing.expectEqualStrings("en-US", site.language);
    try std.testing.expectEqualStrings("+09:00", site.timezone);
    try std.testing.expectEqualStrings("Example Author", site.author);

    const head = try renderHead(std.testing.allocator, site);
    defer std.testing.allocator.free(head);
    try std.testing.expect(std.mem.indexOf(u8, head, "<meta name=\"author\" content=\"Example Author\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "<meta name=\"zlog:timezone\" content=\"+09:00\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "speculationrules") == null);
}

test "site config rejects invalid metadata fields" {
    try std.testing.expectError(error.InvalidSite, validateSiteConfig(.{ .url = "example.com" }, "zlog.ziggy"));
    try std.testing.expectError(error.InvalidSite, validateSiteConfig(.{ .language = "en_US" }, "zlog.ziggy"));
    try std.testing.expectError(error.InvalidSite, validateSiteConfig(.{ .timezone = "Tokyo" }, "zlog.ziggy"));
    try std.testing.expectError(error.InvalidSite, validateSiteConfig(.{ .author = "Bad\nAuthor" }, "zlog.ziggy"));
}

test "frontmatter parser reads title tags and draft" {
    const text =
        \\.title = "Post",
        \\.date = "2026-06-27",
        \\.tags = ["zig", "ssg"],
        \\.draft = false,
    ;
    const fm = try parseFrontmatter(std.testing.allocator, text, "post.md", 1, .post);
    defer std.testing.allocator.free(fm.tags);
    try std.testing.expectEqualStrings("Post", fm.title);
    try std.testing.expectEqual(@as(usize, 2), fm.tags.len);
    try std.testing.expect(!fm.draft);
}

test "frontmatter parser rejects schema type mismatches" {
    const text =
        \\.title = "Post",
        \\.date = "2026-06-27",
        \\.tags = "zig",
    ;
    try std.testing.expectError(error.InvalidSite, parseFrontmatter(std.testing.allocator, text, "post.md", 1, .post));
}

test "frontmatter parser reports malformed Ziggy syntax" {
    const text =
        \\.title = "Post
    ;
    try std.testing.expectError(error.InvalidSite, parseFrontmatter(std.testing.allocator, text, "post.md", 1, .post));
}

test "post schema requires title and date" {
    const text =
        \\.title = "Post",
    ;
    try std.testing.expectError(error.InvalidSite, parseFrontmatter(std.testing.allocator, text, "posts/post.md", 1, .post));
}

test "page schema applies defaults without post date" {
    const text =
        \\.title = "Page",
    ;
    const fm = try parseFrontmatter(std.testing.allocator, text, "page.md", 1, .page);
    defer std.testing.allocator.free(fm.tags);
    try std.testing.expectEqualStrings("Page", fm.title);
    try std.testing.expectEqualStrings("", fm.date);
    try std.testing.expectEqualStrings("base.shtml", fm.layout);
    try std.testing.expect(!fm.draft);
}

test "draft pages are excluded from published outputs" {
    var pages = [_]Page{
        .{ .source_path = "content/index.md", .slug = "index", .url = "/", .fm = .{ .title = "Home" }, .markdown = "", .html = "", .is_post = false },
        .{ .source_path = "content/posts/live.md", .slug = "live", .url = "/live/", .fm = .{ .title = "Live", .date = "2026-06-27" }, .markdown = "", .html = "", .is_post = true },
        .{ .source_path = "content/posts/draft.md", .slug = "draft", .url = "/draft/", .fm = .{ .title = "Draft", .date = "2026-06-27", .draft = true }, .markdown = "", .html = "", .is_post = true },
    };
    try std.testing.expectEqual(@as(usize, 2), countPublishedPages(pages[0..]));
    const rss = try renderRss(std.testing.allocator, pages[0..], .{ .title = "Site" });
    defer std.testing.allocator.free(rss);
    try std.testing.expect(std.mem.indexOf(u8, rss, "Live") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "Draft") == null);
}

test "rss output uses absolute escaped item metadata" {
    var pages = [_]Page{
        .{ .source_path = "content/posts/live.md", .slug = "live", .url = "/live/", .fm = .{ .title = "A & B", .date = "2026-06-27T00:00:00Z", .updated = "2026-06-28T00:00:00Z" }, .markdown = "", .html = "<p>A & B</p>", .is_post = true },
        .{ .source_path = "content/posts/draft.md", .slug = "draft", .url = "/draft/", .fm = .{ .title = "Draft", .date = "2026-06-27T00:00:00Z", .draft = true }, .markdown = "", .html = "", .is_post = true },
    };
    const rss = try renderRss(std.testing.allocator, pages[0..], .{ .title = "Site & Feed", .url = "https://example.com/blog/", .language = "en-US", .author = "Example Author" });
    defer std.testing.allocator.free(rss);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<link>https://example.com/blog/live/</link>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<guid isPermaLink=\"true\">https://example.com/blog/live/</guid>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<language>en-US</language>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<dc:creator>Example Author</dc:creator>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<title>A &amp; B</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<pubDate>Sat, 27 Jun 2026 00:00:00 +0000</pubDate>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<lastBuildDate>Sun, 28 Jun 2026 00:00:00 +0000</lastBuildDate>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<description>&lt;p&gt;A &amp; B&lt;/p&gt;</description>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "<dc:date>2026-06-28T00:00:00Z</dc:date>") != null);
    try std.testing.expect(std.mem.indexOf(u8, rss, "Draft") == null);
}

test "rss date formatting converts iso timestamps" {
    const dated = try formatRssDate(std.testing.allocator, "2026-06-23", "UTC");
    defer std.testing.allocator.free(dated);
    try std.testing.expectEqualStrings("Tue, 23 Jun 2026 00:00:00 +0000", dated);

    const offset = try formatRssDate(std.testing.allocator, "2026-06-23T00:00:00+09:00", "UTC");
    defer std.testing.allocator.free(offset);
    try std.testing.expectEqualStrings("Tue, 23 Jun 2026 00:00:00 +0900", offset);

    const site_zone = try formatRssDate(std.testing.allocator, "2026-06-23", "+09:00");
    defer std.testing.allocator.free(site_zone);
    try std.testing.expectEqualStrings("Tue, 23 Jun 2026 00:00:00 +0900", site_zone);

    const unchanged = try formatRssDate(std.testing.allocator, "Tue, 23 Jun 2026 00:00:00 +0900", "UTC");
    defer std.testing.allocator.free(unchanged);
    try std.testing.expectEqualStrings("Tue, 23 Jun 2026 00:00:00 +0900", unchanged);

    const invalid_offset = try formatRssDate(std.testing.allocator, "2026-06-23T00:00:00+99:00", "UTC");
    defer std.testing.allocator.free(invalid_offset);
    try std.testing.expectEqualStrings("2026-06-23T00:00:00+99:00", invalid_offset);
}

test "sitemap output uses absolute urls and reliable lastmod" {
    var pages = [_]Page{
        .{ .source_path = "content/index.md", .slug = "index", .url = "/", .fm = .{ .title = "Home", .date = "2026-06-20" }, .markdown = "", .html = "", .is_post = false },
        .{ .source_path = "content/posts/live.md", .slug = "live", .url = "/live/", .fm = .{ .title = "Live", .date = "2026-06-27", .updated = "2026-06-28T00:00:00Z", .tags = &[_][]const u8{"zig"} }, .markdown = "", .html = "", .is_post = true },
        .{ .source_path = "content/posts/draft.md", .slug = "draft", .url = "/draft/", .fm = .{ .title = "Draft", .date = "2026-06-29", .draft = true, .tags = &[_][]const u8{"zig"} }, .markdown = "", .html = "", .is_post = true },
    };
    var routes = RouteGraph.init(std.testing.allocator);
    defer routes.deinit();
    try routes.add(.{ .kind = .page, .url = "/", .out_path = "" });
    try routes.add(.{ .kind = .post, .url = "/live/", .out_path = "" });
    try routes.add(.{ .kind = .post, .url = "/draft/", .out_path = "" });
    try routes.add(.{ .kind = .tag, .url = "/tags/zig/", .out_path = "" });
    try routes.add(.{ .kind = .archive, .url = "/archive/", .out_path = "" });
    try routes.add(.{ .kind = .rss, .url = "/rss.xml", .out_path = "" });
    try routes.add(.{ .kind = .sitemap, .url = "/sitemap.xml", .out_path = "" });
    try routes.add(.{ .kind = .static_asset, .url = "/app.css", .out_path = "" });

    const sitemap = try renderSitemap(std.testing.allocator, routes, pages[0..], .{ .url = "https://example.com/blog/" });
    defer std.testing.allocator.free(sitemap);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "<loc>https://example.com/blog/</loc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "<loc>https://example.com/blog/live/</loc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "<loc>https://example.com/blog/tags/zig/</loc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "<loc>https://example.com/blog/archive/</loc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "<lastmod>2026-06-28T00:00:00Z</lastmod>") != null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "https://example.com/blog/draft/") == null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "https://example.com/blog/rss.xml") == null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "https://example.com/blog/sitemap.xml") == null);
    try std.testing.expect(std.mem.indexOf(u8, sitemap, "https://example.com/blog/app.css") == null);
}

test "route graph centralizes published routes and static assets" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/static/assets/icons");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/app.css", .data = "body{}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/assets/icons/logo.bin", .data = &.{ 0x00, 0xff, 0x42 } });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{
        .{ .source_path = "content/index.md", .slug = "index", .url = "/", .fm = .{ .title = "Home" }, .markdown = "", .html = "", .is_post = false },
        .{ .source_path = "content/posts/live.md", .slug = "live", .url = "/live/", .fm = .{ .title = "Live", .date = "2026-06-27", .tags = &[_][]const u8{"zig"} }, .markdown = "", .html = "", .is_post = true },
        .{ .source_path = "content/posts/draft.md", .slug = "draft", .url = "/draft/", .fm = .{ .title = "Draft", .date = "2026-06-27", .draft = true }, .markdown = "", .html = "", .is_post = true },
    };

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    try std.testing.expect(routes.containsUrl("/"));
    try std.testing.expect(routes.containsUrl("/live/"));
    try std.testing.expect(!routes.containsUrl("/draft/"));
    try std.testing.expect(routes.containsUrl("/tags/zig/"));
    try std.testing.expect(routes.containsUrl("/archive/"));
    try std.testing.expect(routes.containsUrl("/rss.xml"));
    try std.testing.expect(routes.containsUrl("/sitemap.xml"));
    try std.testing.expect(routes.containsUrl("/app.css"));
    try std.testing.expect(routes.containsUrl("/assets/icons/logo.bin"));
}

test "static assets are copied recursively without changing bytes" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/static/assets/icons");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/assets/icons/logo.bin", .data = &.{ 0x00, 0xff, 0x42, 0x7f } });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, &.{});
    defer routes.deinit();
    var assets = try buildAssetGraph(std.testing.allocator, &.{}, routes);
    defer assets.deinit();
    try std.testing.expect(routes.containsUrl("/assets/icons/logo.bin"));
    try std.testing.expect(assets.firstByKindAndUrl(.site_asset, "/assets/icons/logo.bin") != null);
    try copySiteAssets(std.testing.allocator, assets);

    const copied_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/public/assets/icons/logo.bin", .{root});
    defer std.testing.allocator.free(copied_path);
    const copied = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, copied_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xff, 0x42, 0x7f }, copied);
}

test "image dimensions are probed from supported image headers" {
    const png_3x2 = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02 };
    const gif_4x5 = [_]u8{ 'G', 'I', 'F', '8', '9', 'a', 0x04, 0x00, 0x05, 0x00 };
    const jpeg_3x2 = [_]u8{ 0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x02, 0x00, 0x03, 0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00 };

    const png = probeImageDimensions(&png_3x2).?;
    try std.testing.expectEqual(@as(u32, 3), png.width);
    try std.testing.expectEqual(@as(u32, 2), png.height);
    const gif = probeImageDimensions(&gif_4x5).?;
    try std.testing.expectEqual(@as(u32, 4), gif.width);
    try std.testing.expectEqual(@as(u32, 5), gif.height);
    const jpeg = probeImageDimensions(&jpeg_3x2).?;
    try std.testing.expectEqual(@as(u32, 3), jpeg.width);
    try std.testing.expectEqual(@as(u32, 2), jpeg.height);
    try std.testing.expect(isSupportedImagePath("LOGO.PNG"));
}

test "rendered image tags receive known local dimensions" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/static/img");
    const png_3x2 = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R', 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02 };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/img/logo.png", .data = &png_3x2 });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{.{
        .source_path = "content/index.md",
        .slug = "index",
        .url = "/",
        .fm = .{ .title = "Home" },
        .markdown = "![Logo](/img/logo.png)",
        .html = "<p><img src=\"/img/logo.png\" alt=\"Logo\"></p>",
        .is_post = false,
    }};

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    var assets = try buildAssetGraph(std.testing.allocator, pages[0..], routes);
    defer assets.deinit();
    const route = findPageRoute(routes, "/").?;
    const layout =
        \\<html><body><main><img src="/img/logo.png" alt="Template" width="3"><template z-replace="content"></template></main></body></html>
    ;
    const html = try renderPageOutputHtml(std.testing.allocator, .{ .path = "<test layout>", .html = layout }, .{}, pages[0], pages[0].html, "", "", "", route.out_path, assets);
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "src=\"/img/logo.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "alt=\"Logo\" width=\"3\" height=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "alt=\"Template\" width=\"3\" height=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "width=\"3\" width=\"3\"") == null);
}

test "internal link validation resolves anchors route variants relative links and assets" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/static");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/app.css", .data = "body{}" });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{
        .{
            .source_path = "content/index.md",
            .slug = "index",
            .url = "/",
            .fm = .{ .title = "Home" },
            .markdown =
            \\# Intro
            \\
            \\[Post](/post#details)
            \\[Asset](/app.css)
            ,
            .html = "<h1 id=\"intro\">Intro</h1>",
            .is_post = false,
        },
        .{
            .source_path = "content/posts/post.md",
            .slug = "post",
            .url = "/post/",
            .fm = .{ .title = "Post", .date = "2026-06-27", .tags = &[_][]const u8{"zig"} },
            .markdown =
            \\## Details
            \\
            \\[Home](../#intro)
            \\[Self](/post)
            \\[Tag](/tags/zig/)
            \\[Feed](/rss.xml)
            ,
            .html = "<h2 id=\"details\">Details</h2>",
            .is_post = true,
        },
    };

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    var assets = try buildAssetGraph(std.testing.allocator, pages[0..], routes);
    defer assets.deinit();
    const page_asset = assets.firstByKindAndUrl(.page_asset, "/app.css").?;
    const site_asset = assets.firstByKindAndUrl(.site_asset, "/app.css").?;
    const build_asset = assets.firstByKindAndUrl(.build_asset, "/").?;
    const static_source_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/static/app.css", .{root});
    defer std.testing.allocator.free(static_source_path);
    const static_out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/public/app.css", .{root});
    defer std.testing.allocator.free(static_out_path);
    const page_out_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/public/index.html", .{root});
    defer std.testing.allocator.free(page_out_path);
    try std.testing.expectEqualStrings("content/index.md", page_asset.owner_path);
    try std.testing.expectEqualStrings(static_source_path, page_asset.source_path);
    try std.testing.expectEqualStrings("/app.css", page_asset.url);
    try std.testing.expectEqualStrings(static_out_path, page_asset.out_path);
    try std.testing.expectEqualStrings("", site_asset.owner_path);
    try std.testing.expectEqualStrings(static_source_path, site_asset.source_path);
    try std.testing.expectEqualStrings(static_out_path, site_asset.out_path);
    try std.testing.expectEqualStrings("content/index.md", build_asset.owner_path);
    try std.testing.expectEqualStrings(page_out_path, build_asset.out_path);
    try std.testing.expect(assets.countByKind(.site_asset) >= 1);
    try std.testing.expect(assets.countByKind(.build_asset) >= 1);
    try std.testing.expect(assets.countByKind(.page_asset) >= 1);
    try validatePages(std.testing.allocator, pages[0..], routes);
}

test "internal link validation rejects unknown anchors" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{
        .{
            .source_path = "content/index.md",
            .slug = "index",
            .url = "/",
            .fm = .{ .title = "Home" },
            .markdown =
            \\# Intro
            \\
            \\[Missing](#missing)
            ,
            .html = "<h1 id=\"intro\">Intro</h1>",
            .is_post = false,
        },
    };

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    try std.testing.expectError(error.InvalidSite, validatePages(std.testing.allocator, pages[0..], routes));
}

test "internal link validation rejects unknown relative routes" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{
        .{
            .source_path = "content/posts/post.md",
            .slug = "post",
            .url = "/post/",
            .fm = .{ .title = "Post", .date = "2026-06-27" },
            .markdown =
            \\# Post
            \\
            \\[Missing](../missing/)
            ,
            .html = "<h1 id=\"post\">Post</h1>",
            .is_post = true,
        },
    };

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    try std.testing.expectError(error.InvalidSite, validatePages(std.testing.allocator, pages[0..], routes));
}

test "template renderer applies attributes and raw slots" {
    const page = Page{
        .source_path = "content/posts/post.md",
        .slug = "post",
        .url = "/post/",
        .fm = .{ .title = "A & B", .date = "2026-06-27", .tags = &[_][]const u8{"zig"}, .transition = "post title" },
        .markdown = "",
        .html = "",
        .is_post = true,
    };
    const html = try renderLayout(std.testing.allocator, initPostLayout, "<test layout>", .{ .title = "Example" }, page, "<p>Body</p>", "", "", "");
    defer std.testing.allocator.free(html);

    try std.testing.expect(std.mem.indexOf(u8, html, "<title>A &amp; B - Example</title>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 style=\"view-transition-name:post-title\">A &amp; B</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>Body</p>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "z-text") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "z-replace") == null);
}

test "template renderer rejects invalid structure and legacy tokens" {
    const page = Page{ .source_path = "content/index.md", .slug = "index", .url = "/", .fm = .{ .title = "Home" }, .markdown = "", .html = "", .is_post = false };
    const ctx = TemplateContext{
        .site = .{},
        .page = page,
        .content = "",
        .post_list = "",
        .head = "",
        .runtime = "",
        .page_tags = "",
        .page_full_title = "Home - zlog site",
    };
    try std.testing.expectError(error.InvalidSite, renderTemplate(std.testing.allocator, "<main><p></main>", "<test layout>", ctx));
    try std.testing.expectError(error.InvalidSite, renderTemplate(std.testing.allocator, "<main>{{content}}</main>", "<test layout>", ctx));
}

test "html validator reports malformed generated markup" {
    try validateHtmlDocument(std.testing.allocator, "<main><p>Body</p><img src=\"/a.png\"></main>", "public/index.html");
    try std.testing.expectError(error.InvalidSite, validateHtmlDocument(std.testing.allocator, "<main>\n<p>Body</main>", "public/index.html"));
    try std.testing.expectError(error.InvalidSite, validateHtmlDocument(std.testing.allocator, "<main><section></section>", "public/index.html"));
}

test "html validation covers generated listing pages during check" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var pages = [_]Page{
        .{
            .source_path = "content/posts/post.md",
            .slug = "post",
            .url = "/post/",
            .fm = .{ .title = "Post", .date = "2026-06-27", .tags = &[_][]const u8{"bad</h1>"} },
            .markdown = "# Post",
            .html = "<h1 id=\"post\">Post</h1>",
            .is_post = true,
        },
    };

    var routes = try buildRouteGraph(std.testing.allocator, root, .{}, pages[0..]);
    defer routes.deinit();
    const head = try renderHead(std.testing.allocator, .{});
    defer std.testing.allocator.free(head);
    try std.testing.expectError(error.InvalidSite, validateGeneratedListingHtml(std.testing.allocator, routes, pages[0..], .{}, head, prefetchRuntime));
}

test "dev server resolves route paths into public files" {
    const index = try servedFilePath(std.testing.allocator, "public", "/");
    defer std.testing.allocator.free(index);
    try std.testing.expectEqualStrings("public/index.html", index);

    const directory = try servedFilePath(std.testing.allocator, "public", "/posts/hello/");
    defer std.testing.allocator.free(directory);
    try std.testing.expectEqualStrings("public/posts/hello/index.html", directory);

    const extensionless = try servedFilePath(std.testing.allocator, "public", "/posts/hello");
    defer std.testing.allocator.free(extensionless);
    try std.testing.expectEqualStrings("public/posts/hello/index.html", extensionless);

    const asset = try servedFilePath(std.testing.allocator, "public", "/app.css");
    defer std.testing.allocator.free(asset);
    try std.testing.expectEqualStrings("public/app.css", asset);
    try std.testing.expectEqualStrings("text/css; charset=utf-8", contentTypeForPath(asset));
}

test "project fingerprint changes when watched inputs change" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/content");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/content/index.md", .data = "one" });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/site", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const before = try projectFingerprint(std.testing.allocator, root, .{});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/content/index.md", .data = "two two" });
    const after = try projectFingerprint(std.testing.allocator, root, .{});
    try std.testing.expect(before != after);
}

test "markdown renderer emits headings paragraphs and links" {
    const html = try markdownToHtml(std.testing.allocator, "# Hello\n\nGo [home](/)");
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"hello\">Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-z-prefetch") != null);
}

test "markdown renderer handles fenced code tables and emphasis" {
    const html = try markdownToHtml(std.testing.allocator,
        \\| Name | Value |
        \\| --- | --- |
        \\| **zlog** | https://example.com |
        \\
        \\```zig
        \\const x = 1;
        \\```
    );
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "language-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>zlog</strong>") != null);
}

test "markdown renderer enables gfm strikethrough task lists and footnotes" {
    const html = try markdownToHtml(std.testing.allocator,
        \\- [x] shipped
        \\- [ ] pending
        \\
        \\~~removed~~ text with a footnote.[^1]
        \\
        \\[^1]: Footnote body.
    );
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<del>removed</del>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "checkbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "footnotes") != null);
}

test "transition names are safe css identifiers" {
    const id = try safeCssIdent(std.testing.allocator, "post-title:Hello Zig!");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("post-title-hello-zig", id);
}
