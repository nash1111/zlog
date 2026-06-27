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

const Page = struct {
    source_path: []const u8,
    slug: []const u8,
    url: []const u8,
    fm: Frontmatter,
    markdown: []const u8,
    html: []const u8,
    is_post: bool,
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
        try cmdBuild(allocator, dir);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try cmdBuild(allocator, dir);
        try stdout("dev server MVP: rebuilt once. file watch/live reload are next.\n", .{});
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
    try validatePages(allocator, pages.items);
    try stdout("check ok: {d} pages\n", .{pages.items.len});
}

fn cmdBuild(allocator: std.mem.Allocator, dir: []const u8) !void {
    const site = try loadSite(allocator, dir);
    var pages = try loadPages(allocator, dir, site);
    defer pages.deinit();
    try validatePages(allocator, pages.items);

    const out_dir = try join(allocator, &.{ dir, site.out_dir });
    try cleanAndCreate(out_dir);
    try copyStaticIfPresent(allocator, dir, out_dir);

    const post_list = try renderPostList(allocator, pages.items, site);
    const head = renderHead(site);
    const runtime = prefetchRuntime;

    for (pages.items) |page| {
        const layout_name = if (page.fm.layout.len == 0) "base.shtml" else page.fm.layout;
        const layout_path = try join(allocator, &.{ dir, site.layouts_dir, layout_name });
        const layout = std.Io.Dir.cwd().readFileAlloc(runtime_io, layout_path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => if (page.is_post) initPostLayout else initBaseLayout,
            else => return err,
        };
        const rendered = try renderLayout(allocator, layout, site, page, page.html, post_list, head, runtime);
        const final_html = try rewriteNavigationAttributes(allocator, rendered, site.prefetch_default);
        const rel = if (std.mem.eql(u8, page.url, "/")) "index.html" else try std.fmt.allocPrint(allocator, "{s}index.html", .{std.mem.trimStart(u8, page.url, "/")});
        const out_path = try join(allocator, &.{ out_dir, rel });
        try writeAll(allocator, out_path, final_html);
    }

    try renderTagPages(allocator, out_dir, pages.items, site, head, runtime);
    try renderArchivePage(allocator, out_dir, pages.items, site, head, runtime);
    try writeAll(allocator, try join(allocator, &.{ out_dir, "rss.xml" }), try renderRss(allocator, pages.items, site));
    try writeAll(allocator, try join(allocator, &.{ out_dir, "sitemap.xml" }), try renderSitemap(allocator, pages.items));
    try stdout("built {d} pages into {s}\n", .{ pages.items.len, out_dir });
}

fn loadSite(allocator: std.mem.Allocator, dir: []const u8) !SiteConfig {
    const path = try join(allocator, &.{ dir, "zlog.ziggy" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime_io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return SiteConfig{},
        else => return err,
    };
    return SiteConfig{
        .title = parseStringField(text, "title") orelse "zlog site",
        .content_dir = parseStringField(text, "content_dir") orelse "content",
        .layouts_dir = parseStringField(text, "layouts_dir") orelse "layouts",
        .out_dir = parseStringField(text, "out_dir") orelse "public",
        .prefetch_default = parseStringField(text, "prefetch_default") orelse "hover",
        .speculation_rules = parseBoolField(text, "speculation_rules") orelse true,
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
    const fm = try parseFrontmatter(allocator, split.frontmatter);
    const rel = std.mem.trimStart(u8, path[content_root.len..], std.Io.Dir.path.sep_str);
    const is_post = std.mem.startsWith(u8, rel, "posts/");
    const slug = slugFromPath(rel);
    const url = if (std.mem.eql(u8, rel, "index.md")) try allocator.dupe(u8, "/") else try std.fmt.allocPrint(allocator, "/{s}/", .{slug});
    const html = try markdownToHtml(allocator, split.body);
    return Page{ .source_path = path, .slug = slug, .url = url, .fm = fm, .markdown = split.body, .html = html, .is_post = is_post };
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
        .date = parseStringField(text, "date") orelse "",
        .layout = parseStringField(text, "layout") orelse "base.shtml",
        .tags = try parseStringArrayField(allocator, text, "tags"),
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
    return &.{};
}

fn markdownToHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var in_list = false;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "#")) {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            if (level > 6) level = 6;
            const title = std.mem.trimStart(u8, line[level..], " ");
            const id = try slugify(allocator, title);
            defer allocator.free(id);
            try out.print("<h{d} id=\"{s}\">", .{ level, id });
            try appendEscaped(&out, title);
            try out.print("</h{d}>\n", .{level});
        } else if (std.mem.startsWith(u8, line, "- ")) {
            if (!in_list) {
                try out.appendSlice("<ul>\n");
                in_list = true;
            }
            try out.appendSlice("<li>");
            try renderInlineMarkdown(allocator, &out, line[2..]);
            try out.appendSlice("</li>\n");
        } else {
            if (in_list) {
                try out.appendSlice("</ul>\n");
                in_list = false;
            }
            try out.appendSlice("<p>");
            try renderInlineMarkdown(allocator, &out, line);
            try out.appendSlice("</p>\n");
        }
    }
    if (in_list) try out.appendSlice("</ul>\n");
    return out.toOwnedSlice();
}

fn renderInlineMarkdown(allocator: std.mem.Allocator, out: *std.array_list.Managed(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i, ']')) |close_label| {
                if (close_label + 1 < text.len and text[close_label + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_label + 2, ')')) |close_url| {
                        const label = text[i + 1 .. close_label];
                        const url = text[close_label + 2 .. close_url];
                        try out.appendSlice("<a href=\"");
                        try appendEscaped(out, url);
                        try out.appendSlice("\" data-z-prefetch>");
                        try appendEscaped(out, label);
                        try out.appendSlice("</a>");
                        i = close_url + 1;
                        _ = allocator;
                        continue;
                    }
                }
            }
        }
        try appendEscapedChar(out, text[i]);
        i += 1;
    }
}

fn validatePages(allocator: std.mem.Allocator, pages: []Page) !void {
    for (pages) |page| {
        if (page.fm.title.len == 0) return fail("missing .title in {s}", .{page.source_path});
        if (page.is_post and page.fm.date.len == 0) return fail("missing .date in post {s}", .{page.source_path});
        try validateDuplicateHeadings(allocator, page);
        try validateInternalLinks(page, pages);
    }
}

fn fail(comptime fmt: []const u8, args: anytype) !void {
    try stderr("error: " ++ fmt ++ "\n", args);
    return error.InvalidSite;
}

fn validateDuplicateHeadings(allocator: std.mem.Allocator, page: Page) !void {
    var ids = std.StringHashMap(void).init(allocator);
    var lines = std.mem.splitScalar(u8, page.markdown, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            const title = std.mem.trimStart(u8, line[level..], " ");
            const id = try slugify(allocator, title);
            if (ids.contains(id)) return fail("duplicate heading id '{s}' in {s}", .{ id, page.source_path });
            try ids.put(id, {});
        }
    }
}

fn validateInternalLinks(page: Page, pages: []Page) !void {
    var rest = page.markdown;
    while (std.mem.indexOf(u8, rest, "](")) |idx| {
        rest = rest[idx + 2 ..];
        const end = std.mem.indexOfScalar(u8, rest, ')') orelse break;
        const url = rest[0..end];
        if (std.mem.startsWith(u8, url, "/") and !std.mem.startsWith(u8, url, "//")) {
            var ok = std.mem.eql(u8, url, "/rss.xml") or std.mem.eql(u8, url, "/sitemap.xml");
            for (pages) |p| {
                if (std.mem.eql(u8, p.url, url)) ok = true;
            }
            if (!ok) return fail("broken internal link '{s}' in {s}", .{ url, page.source_path });
        }
        rest = rest[end + 1 ..];
    }
}

fn renderLayout(allocator: std.mem.Allocator, layout: []const u8, site: SiteConfig, page: Page, content: []const u8, post_list: []const u8, head: []const u8, runtime: []const u8) ![]const u8 {
    var out = try replaceAll(allocator, layout, "{{site.title}}", site.title);
    out = try replaceAll(allocator, out, "{{page.title}}", page.fm.title);
    out = try replaceAll(allocator, out, "{{page.date}}", page.fm.date);
    out = try replaceAll(allocator, out, "{{page.transition}}", page.fm.transition);
    out = try replaceAll(allocator, out, "{{page.tags}}", try renderTagsInline(allocator, page.fm.tags));
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
        try out.print("<a href=\"/tags/{s}/\" data-z-prefetch=\"hover\">#{s}</a>", .{ try slugify(allocator, tag), tag });
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
        try out.print(" style=\"view-transition-name:{s}\"", .{name});
        rest = rest[end + 1 ..];
    }
    try out.appendSlice(rest);
    return out.toOwnedSlice();
}

fn renderTagPages(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) !void {
    var seen = std.StringHashMap(void).init(allocator);
    for (pages) |p| if (p.is_post) for (p.fm.tags) |tag| {
        const tag_slug = try slugify(allocator, tag);
        if (seen.contains(tag_slug)) continue;
        try seen.put(tag_slug, {});
        var body = std.array_list.Managed(u8).init(allocator);
        try body.print("<h1>#{s}</h1>\n<ul>\n", .{tag});
        for (pages) |q| if (q.is_post and hasTag(q, tag)) {
            try body.print("<li><a href=\"{s}\" data-z-prefetch=\"hover\">{s}</a></li>\n", .{ q.url, q.fm.title });
        };
        try body.appendSlice("</ul>");
        const fake = Page{ .source_path = "", .slug = tag_slug, .url = "", .fm = .{ .title = tag, .layout = "base.shtml" }, .markdown = "", .html = "", .is_post = false };
        const layout = initBaseLayout;
        const rendered = try renderLayout(allocator, layout, site, fake, try body.toOwnedSlice(), "", head, runtime);
        try writeAll(allocator, try join(allocator, &.{ out_dir, "tags", tag_slug, "index.html" }), rendered);
    };
}

fn renderArchivePage(allocator: std.mem.Allocator, out_dir: []const u8, pages: []Page, site: SiteConfig, head: []const u8, runtime: []const u8) !void {
    var body = std.array_list.Managed(u8).init(allocator);
    try body.appendSlice("<h1>Archive</h1>\n<ul>\n");
    for (pages) |p| if (p.is_post) try body.print("<li><time>{s}</time> <a href=\"{s}\" data-z-prefetch=\"hover\">{s}</a></li>\n", .{ p.fm.date, p.url, p.fm.title });
    try body.appendSlice("</ul>");
    const fake = Page{ .source_path = "", .slug = "archive", .url = "/archive/", .fm = .{ .title = "Archive", .layout = "base.shtml" }, .markdown = "", .html = "", .is_post = false };
    const rendered = try renderLayout(allocator, initBaseLayout, site, fake, try body.toOwnedSlice(), "", head, runtime);
    try writeAll(allocator, try join(allocator, &.{ out_dir, "archive", "index.html" }), rendered);
}

fn renderRss(allocator: std.mem.Allocator, pages: []Page, site: SiteConfig) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.print("<?xml version=\"1.0\" encoding=\"utf-8\"?><rss version=\"2.0\"><channel><title>{s}</title>", .{site.title});
    for (pages) |p| if (p.is_post) try out.print("<item><title>{s}</title><link>{s}</link><pubDate>{s}</pubDate></item>", .{ p.fm.title, p.url, p.fm.date });
    try out.appendSlice("</channel></rss>\n");
    return out.toOwnedSlice();
}

fn renderSitemap(allocator: std.mem.Allocator, pages: []Page) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<?xml version=\"1.0\" encoding=\"utf-8\"?><urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">");
    for (pages) |p| try out.print("<url><loc>{s}</loc></url>", .{p.url});
    try out.appendSlice("</urlset>\n");
    return out.toOwnedSlice();
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
    const html = try markdownToHtml(std.testing.allocator, "# Hello\n\nGo [home](/)");
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1 id=\"hello\">Hello</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-z-prefetch") != null);
}

test "transition names are safe css identifiers" {
    const id = try safeCssIdent(std.testing.allocator, "post-title:Hello Zig!");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("post-title-hello-zig", id);
}
