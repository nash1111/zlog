const std = @import("std");
var runtime_io: std.Io = undefined;

const SiteConfig = struct {
    title: []const u8 = "zlog site",
    content_dir: []const u8 = "content",
    layouts_dir: []const u8 = "layouts",
    out_dir: []const u8 = "public",
    prefetch_default: []const u8 = "hover",
    speculation_rules: bool = true,
};

const Frontmatter = struct {
    title: []const u8 = "",
    date: []const u8 = "",
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

const CliError = error{Usage};
const default_dev_port: u16 = 1111;

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
    try validatePages(allocator, pages.items, routes);
    try validateRenderedHtml(allocator, dir, site, pages.items, routes);
    try stdout("check ok: {d} pages\n", .{pages.items.len});
}

fn cmdBuild(allocator: std.mem.Allocator, dir: []const u8) !void {
    const site = try loadSite(allocator, dir);
    var pages = try loadPages(allocator, dir, site);
    defer pages.deinit();
    var routes = try buildRouteGraph(allocator, dir, site, pages.items);
    defer routes.deinit();
    try validatePages(allocator, pages.items, routes);

    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try cleanAndCreate(out_dir);
    try copyStaticRoutes(allocator, routes);

    const post_list = try renderPostList(allocator, pages.items, site);
    const head = renderHead(site);
    const runtime = prefetchRuntime;

    for (pages.items) |page| {
        if (page.fm.draft) continue;
        const route = findPageRoute(routes, page.url) orelse return fail("missing route for {s}", .{page.url});
        const layout = try loadLayoutForPage(allocator, dir, site, page);
        const final_html = try renderPageOutputHtml(allocator, layout, site, page, page.html, post_list, head, runtime, route.out_path);
        try writeAll(allocator, route.out_path, final_html);
    }

    try renderTagPages(allocator, routes, pages.items, site, head, runtime);
    try renderArchivePage(allocator, routes, pages.items, site, head, runtime);
    const rss_route = routes.firstByKind(.rss) orelse return fail("missing RSS route", .{});
    try writeAll(allocator, rss_route.out_path, try renderRss(allocator, pages.items, site));
    const sitemap_route = routes.firstByKind(.sitemap) orelse return fail("missing sitemap route", .{});
    try writeAll(allocator, sitemap_route.out_path, try renderSitemap(allocator, routes));
    try stdout("built {d} pages into {s}\n", .{ countPublishedPages(pages.items), out_dir });
}

fn cmdDev(allocator: std.mem.Allocator, dir: []const u8, port: u16) !void {
    try cmdBuild(allocator, dir);
    const site = try loadSite(allocator, dir);
    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try serveDirectory(allocator, out_dir, port);
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

fn validateRenderedHtml(allocator: std.mem.Allocator, dir: []const u8, site: SiteConfig, pages: []Page, routes: RouteGraph) !void {
    const post_list = try renderPostList(allocator, pages, site);
    const head = renderHead(site);
    const runtime = prefetchRuntime;

    for (pages) |page| {
        if (page.fm.draft) continue;
        const route = findPageRoute(routes, page.url) orelse return fail("missing route for {s}", .{page.url});
        const layout = try loadLayoutForPage(allocator, dir, site, page);
        const final_html = try renderPageOutputHtml(allocator, layout, site, page, page.html, post_list, head, runtime, route.out_path);
        allocator.free(final_html);
    }

    try validateGeneratedListingHtml(allocator, routes, pages, site, head, runtime);
}

fn renderPageOutputHtml(allocator: std.mem.Allocator, layout: LayoutSource, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8, output_path: []const u8) ![]const u8 {
    try validateHtmlDocument(allocator, layout.html, layout.path);
    const rendered = try renderLayout(allocator, layout.html, site, page, content, post_list, head, runtime);
    defer allocator.free(rendered);
    const final_html = try rewriteNavigationAttributes(allocator, rendered, site.prefetch_default);
    errdefer allocator.free(final_html);
    try validateHtmlDocument(allocator, final_html, output_path);
    return final_html;
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
    return SiteConfig{
        .title = try ziggyString(doc, path, "title", "zlog site"),
        .content_dir = try ziggyString(doc, path, "content_dir", "content"),
        .layouts_dir = try ziggyString(doc, path, "layouts_dir", "layouts"),
        .out_dir = try ziggyString(doc, path, "out_dir", "public"),
        .prefetch_default = try ziggyString(doc, path, "prefetch_default", "hover"),
        .speculation_rules = try ziggyBool(doc, path, "speculation_rules", true),
    };
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
    return Page{ .source_path = path, .slug = slug, .url = url, .fm = fm, .markdown = split.body, .html = html, .is_post = is_post };
}

const FrontmatterSplit = struct {
    frontmatter: []const u8,
    body: []const u8,
    frontmatter_line: usize,
};

fn splitFrontmatter(text: []const u8) FrontmatterSplit {
    if (!std.mem.startsWith(u8, text, "---")) return .{ .frontmatter = "", .body = text, .frontmatter_line = 1 };
    const rest = text[3..];
    if (std.mem.indexOf(u8, rest, "\n---")) |idx| {
        const body_start = 3 + idx + 4;
        return .{ .frontmatter = std.mem.trim(u8, rest[0..idx], " \t\r\n"), .body = std.mem.trimStart(u8, text[body_start..], "\r\n"), .frontmatter_line = 2 };
    }
    return .{ .frontmatter = "", .body = text, .frontmatter_line = 1 };
}

fn parseFrontmatter(allocator: std.mem.Allocator, text: []const u8, path: []const u8, line_start: usize, collection: ContentCollection) !Frontmatter {
    const doc = try parseZiggyFields(allocator, text, path, line_start);
    defer allocator.free(doc.fields);
    return Frontmatter{
        .title = try ziggyRequiredString(doc, path, line_start, "title"),
        .date = if (collection == .post) try ziggyRequiredString(doc, path, line_start, "date") else try ziggyString(doc, path, "date", ""),
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
        if (self.isDone() or self.peek() != expected) return self.fail("expected '{c}'", .{expected});
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
            return self.fail("expected field name", .{});
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
                    if (self.isDone()) return self.fail("unterminated object", .{});
                    if (self.peek() == '}') {
                        _ = self.advance();
                        break;
                    }
                    try self.parseField();
                }
                break :blk .object;
            },
            else => self.fail("unsupported Ziggy value", .{}),
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
            if (c == '\n') return self.fail("unterminated string", .{});
            if (c == '\\') {
                _ = self.advance();
                if (self.isDone()) return self.fail("unterminated escape sequence", .{});
            }
            _ = self.advance();
        }
        return self.fail("unterminated string", .{});
    }

    fn parseStringArray(self: *ZiggyParser) anyerror![]const []const u8 {
        try self.expect('[');
        var values = std.array_list.Managed([]const u8).init(self.allocator);
        while (true) {
            try self.skipIgnored();
            if (self.isDone()) return self.fail("unterminated array", .{});
            if (self.peek() == ']') {
                _ = self.advance();
                return values.toOwnedSlice();
            }
            if (self.peek() != '"') return self.fail("expected string in array", .{});
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
        return self.fail("expected bool", .{});
    }
};

fn ziggyString(doc: ZiggyDoc, path: []const u8, name: []const u8, default: []const u8) ![]const u8 {
    const field = doc.find(name) orelse return default;
    return switch (field.value) {
        .string => |value| value,
        else => {
            try failAt(path, field.line, field.column, ".{s} must be a string", .{name});
            unreachable;
        },
    };
}

fn ziggyRequiredString(doc: ZiggyDoc, path: []const u8, line: usize, name: []const u8) ![]const u8 {
    const field = doc.find(name) orelse {
        try failAt(path, line, 1, "missing required field .{s}", .{name});
        unreachable;
    };
    return switch (field.value) {
        .string => |value| if (value.len > 0) value else {
            try failAt(path, field.line, field.column, ".{s} must not be empty", .{name});
            unreachable;
        },
        else => {
            try failAt(path, field.line, field.column, ".{s} must be a string", .{name});
            unreachable;
        },
    };
}

fn ziggyBool(doc: ZiggyDoc, path: []const u8, name: []const u8, default: bool) !bool {
    const field = doc.find(name) orelse return default;
    return switch (field.value) {
        .bool => |value| value,
        else => {
            try failAt(path, field.line, field.column, ".{s} must be a bool", .{name});
            unreachable;
        },
    };
}

fn ziggyStringArray(doc: ZiggyDoc, path: []const u8, name: []const u8) ![]const []const u8 {
    const field = doc.find(name) orelse return &.{};
    return switch (field.value) {
        .string_array => |value| value,
        else => {
            try failAt(path, field.line, field.column, ".{s} must be an array of strings", .{name});
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
        if (page.fm.title.len == 0) return fail("missing .title in {s}", .{page.source_path});
        if (page.is_post and page.fm.date.len == 0) return fail("missing .date in post {s}", .{page.source_path});
        try validateDuplicateHeadings(allocator, page);
        try validateInternalLinks(allocator, page, pages, routes);
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

fn validateDuplicateHeadings(allocator: std.mem.Allocator, page: Page) !void {
    var ids = std.StringHashMap(void).init(allocator);
    defer {
        var keys = ids.keyIterator();
        while (keys.next()) |id| allocator.free(id.*);
        ids.deinit();
    }

    var lines = std.mem.splitScalar(u8, page.markdown, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            const title = std.mem.trimStart(u8, line[level..], " ");
            const id = try slugify(allocator, title);
            if (ids.contains(id)) {
                defer allocator.free(id);
                return fail("duplicate heading id '{s}' in {s}", .{ id, page.source_path });
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
    var rest = page.markdown;
    while (std.mem.indexOf(u8, rest, "](")) |idx| {
        rest = rest[idx + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const destination = markdownLinkDestination(rest[0..end]);
        if (try resolveInternalLink(allocator, page.url, destination)) |link| {
            defer link.deinit(allocator);
            const route = findRouteForLink(routes, link.path) orelse return fail("broken internal link '{s}' in {s}", .{ destination, page.source_path });
            if (link.fragment.len > 0 and (route.kind == .page or route.kind == .post)) {
                const target = findPageByUrl(pages, route.url) orelse return fail("broken internal link '{s}' in {s}", .{ destination, page.source_path });
                if (!htmlHasId(target.html, link.fragment)) return fail("broken internal anchor '{s}' in {s}", .{ destination, page.source_path });
            } else if (link.fragment.len > 0) {
                return fail("broken internal anchor '{s}' in {s}", .{ destination, page.source_path });
            }
        }
        rest = rest[end + 1 ..];
    }
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
    var d = std.Io.Dir.cwd().openDir(runtime_io, static_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return graph,
        else => return err,
    };
    defer d.close(runtime_io);
    var it = d.iterate();
    while (try it.next(runtime_io)) |entry| {
        if (entry.kind != .file) continue;
        try graph.add(.{
            .kind = .static_asset,
            .source_path = try graph.own(try join(allocator, &.{ static_dir, entry.name })),
            .url = try graph.own(try std.fmt.allocPrint(allocator, "/{s}", .{entry.name})),
            .out_path = try graph.own(try join(allocator, &.{ out_dir, entry.name })),
        });
    }

    return graph;
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

fn copyStaticRoutes(allocator: std.mem.Allocator, routes: RouteGraph) !void {
    for (routes.routes.items) |route| {
        if (route.kind != .static_asset) continue;
        const data = try std.Io.Dir.cwd().readFileAlloc(runtime_io, route.source_path, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(data);
        try writeAll(allocator, route.out_path, data);
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

fn renderLayout(allocator: std.mem.Allocator, layout: []const u8, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8) ![]const u8 {
    const page_tags = try renderTagsInline(allocator, page.fm.tags);
    defer allocator.free(page_tags);
    const page_full_title = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ page.fm.title, site.title });
    defer allocator.free(page_full_title);
    const rendered = try renderTemplate(allocator, layout, .{
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

fn renderTemplate(allocator: std.mem.Allocator, layout: []const u8, ctx: TemplateContext) ![]const u8 {
    if (std.mem.indexOf(u8, layout, "{{") != null) {
        try fail("legacy template token found; use z-text, z-html, z-replace, or z-attr:*", .{});
        unreachable;
    }
    try validateTemplateStructure(allocator, layout);

    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, layout, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, layout, lt, '>') orelse {
            try fail("invalid template HTML structure", .{});
            unreachable;
        };
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
                try fail("missing z-replace value on <{s}>", .{name});
                unreachable;
            };
            const close = findClosingTag(layout, gt + 1, name) orelse {
                try fail("missing closing tag for <{s}>", .{name});
                unreachable;
            };
            try out.appendSlice(try templateValue(ctx, expr));
            i = close.end;
            continue;
        }

        const close = if (action == .text or action == .html)
            findClosingTag(layout, gt + 1, name) orelse {
                try fail("missing closing tag for <{s}>", .{name});
                unreachable;
            }
        else
            null;

        const rendered_tag = try renderTemplateStartTag(allocator, tag, ctx);
        defer allocator.free(rendered_tag);
        try out.appendSlice(rendered_tag);

        if (action == .text or action == .html) {
            const expr = if (action == .text) templateAttrValue(tag, "z-text") orelse {
                try fail("missing z-text value on <{s}>", .{name});
                unreachable;
            } else templateAttrValue(tag, "z-html") orelse {
                try fail("missing z-html value on <{s}>", .{name});
                unreachable;
            };
            const value = try templateValue(ctx, expr);
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

fn templateValue(ctx: TemplateContext, expr: []const u8) ![]const u8 {
    const name = std.mem.trim(u8, expr, " \t\r\n");
    if (std.mem.eql(u8, name, "site.title")) return ctx.site.title;
    if (std.mem.eql(u8, name, "page.title")) return ctx.page.fm.title;
    if (std.mem.eql(u8, name, "page.full_title")) return ctx.page_full_title;
    if (std.mem.eql(u8, name, "page.date")) return ctx.page.fm.date;
    if (std.mem.eql(u8, name, "page.transition")) return ctx.page.fm.transition;
    if (std.mem.eql(u8, name, "page.tags")) return ctx.page_tags;
    if (std.mem.eql(u8, name, "content")) return ctx.content;
    if (std.mem.eql(u8, name, "post_list")) return ctx.post_list;
    if (std.mem.eql(u8, name, "zlog.head")) return ctx.head;
    if (std.mem.eql(u8, name, "zlog.runtime")) return ctx.runtime;
    try fail("unknown template binding '{s}'", .{name});
    unreachable;
}

fn renderTemplateStartTag(allocator: std.mem.Allocator, tag: []const u8, ctx: TemplateContext) ![]const u8 {
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
            const rendered = try templateValue(ctx, value);
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

fn validateTemplateStructure(allocator: std.mem.Allocator, html: []const u8) !void {
    try validateHtmlDocument(allocator, html, "<template>");
}

fn validateHtmlDocument(allocator: std.mem.Allocator, html: []const u8, path: []const u8) !void {
    var stack = std.array_list.Managed(HtmlOpenTag).init(allocator);
    defer stack.deinit();
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            const end = std.mem.indexOf(u8, html[lt + 4 ..], "-->") orelse {
                const loc = sourceLocationAt(html, lt);
                return failAt(path, loc.line, loc.column, "unterminated HTML comment", .{});
            };
            i = lt + 4 + end + 3;
            continue;
        }
        const loc = sourceLocationAt(html, lt);
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return failAt(path, loc.line, loc.column, "unterminated HTML tag", .{});
        const tag = html[lt .. gt + 1];
        if (tag.len >= 2 and (tag[1] == '!' or tag[1] == '?')) {
            i = gt + 1;
            continue;
        }
        if (closingTagName(tag)) |name| {
            if (stack.items.len == 0) return failAt(path, loc.line, loc.column, "unexpected closing tag </{s}>", .{name});
            const open = stack.items[stack.items.len - 1];
            if (!std.ascii.eqlIgnoreCase(open.name, name)) return failAt(path, loc.line, loc.column, "closing tag </{s}> does not match <{s}> opened at {d}:{d}", .{ name, open.name, open.line, open.column });
            _ = stack.pop();
        } else if (startTagName(tag)) |name| {
            if (isRawTextHtmlTag(name)) {
                const close = findClosingTag(html, gt + 1, name) orelse return failAt(path, loc.line, loc.column, "missing closing tag for <{s}>", .{name});
                i = close.end;
                continue;
            }
            if (!isSelfClosingTag(tag) and !isVoidHtmlTag(name)) try stack.append(.{ .name = name, .line = loc.line, .column = loc.column });
        }
        i = gt + 1;
    }
    if (stack.items.len > 0) {
        const open = stack.items[stack.items.len - 1];
        return failAt(path, open.line, open.column, "unclosed HTML tag <{s}>", .{open.name});
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

fn renderHead(site: SiteConfig) []const u8 {
    _ = site;
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
    return renderLayout(allocator, initBaseLayout, site, fake, body_html, "", head, runtime);
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
    return renderLayout(allocator, initBaseLayout, site, fake, body_html, "", head, runtime);
}

fn renderRss(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.print("<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"2.0\"><channel><title>{s}</title>", .{site.title});
    for (pages) |p| if (p.is_post and !p.fm.draft) try out.print("<item><title>{s}</title><link>{s}</link><pubDate>{s}</pubDate></item>", .{ p.fm.title, p.url, p.fm.date });
    try out.appendSlice("</channel></rss>\n");
    return out.toOwnedSlice();
}

fn renderSitemap(allocator: std.mem.Allocator, routes: RouteGraph) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?><urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">");
    for (routes.routes.items) |route| switch (route.kind) {
        .page, .post, .tag, .archive => try out.print("<url><loc>{s}</loc></url>", .{route.url}),
        .rss, .sitemap, .static_asset => {},
    };
    try out.appendSlice("</urlset>\n");
    return out.toOwnedSlice();
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
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title z-text="page.full_title"></title><template z-replace="zlog.head"></template></head>
    \\<body><header><a href="/" data-z-prefetch="hover" z-text="site.title"></a></header><main><template z-replace="content"></template><template z-replace="post_list"></template></main><template z-replace="zlog.runtime"></template></body></html>
;
const initPostLayout =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title z-text="page.full_title"></title><template z-replace="zlog.head"></template></head>
    \\<body><header><a href="/" data-z-prefetch="hover" z-text="site.title"></a></header><article><h1 z-text="page.title" z-attr:z-transition-name="page.transition"></h1><p><time z-text="page.date"></time> <span z-replace="page.tags"></span></p><template z-replace="content"></template></article><template z-replace="zlog.runtime"></template></body></html>
;

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

test "route graph centralizes published routes and static assets" {
    runtime_io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "site/static");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "site/static/app.css", .data = "body{}" });
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
    const html = try renderLayout(std.testing.allocator, initPostLayout, .{ .title = "Example" }, page, "<p>Body</p>", "", "", "");
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
    try std.testing.expectError(error.InvalidSite, renderTemplate(std.testing.allocator, "<main><p></main>", ctx));
    try std.testing.expectError(error.InvalidSite, renderTemplate(std.testing.allocator, "<main>{{content}}</main>", ctx));
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
    try std.testing.expectError(error.InvalidSite, validateGeneratedListingHtml(std.testing.allocator, routes, pages[0..], .{}, renderHead(.{}), prefetchRuntime));
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
