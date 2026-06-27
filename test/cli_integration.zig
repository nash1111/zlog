const std = @import("std");
const cli_options = @import("cli_test_options");

const io = std.testing.io;
const allocator = std.testing.allocator;

const CliResult = struct {
    result: std.process.RunResult,

    fn deinit(self: CliResult) void {
        allocator.free(self.result.stdout);
        allocator.free(self.result.stderr);
    }
};

test "cli init check and build a minimal site" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const site_path = try tempPath(&tmp.sub_path, "site");
    defer allocator.free(site_path);

    const init_result = try runZlog(&.{ "init", site_path });
    defer init_result.deinit();
    try expectExit(init_result, 0);
    try expectOutputContains(init_result, "initialized zlog site");

    const check_result = try runZlog(&.{ "check", site_path });
    defer check_result.deinit();
    try expectExit(check_result, 0);
    try expectOutputContains(check_result, "check ok: 2 pages");

    const build_result = try runZlog(&.{ "build", site_path });
    defer build_result.deinit();
    try expectExit(build_result, 0);
    try expectOutputContains(build_result, "built 2 pages");

    const index_path = try join(site_path, "public/index.html");
    defer allocator.free(index_path);
    const index_html = try std.Io.Dir.cwd().readFileAlloc(io, index_path, allocator, .limited(64 * 1024));
    defer allocator.free(index_html);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "Welcome to a zlog site.") != null);
}

test "cli check reports common invalid inputs" {
    var link_tmp = std.testing.tmpDir(.{});
    defer link_tmp.cleanup();
    const link_site = try tempPath(&link_tmp.sub_path, "site");
    defer allocator.free(link_site);
    try initSite(link_site);
    try writeSiteFile(link_site, "content/index.md",
        \\---
        \\.title = "Home",
        \\.layout = "base.shtml",
        \\---
        \\
        \\# Home
        \\
        \\[Missing](/missing)
        \\
    );

    const link_result = try runZlog(&.{ "check", link_site });
    defer link_result.deinit();
    try expectExit(link_result, 1);
    try expectOutputContains(link_result, "broken internal link '/missing'");
    try expectOutputContains(link_result, "hint:");

    var schema_tmp = std.testing.tmpDir(.{});
    defer schema_tmp.cleanup();
    const schema_site = try tempPath(&schema_tmp.sub_path, "site");
    defer allocator.free(schema_site);
    try initSite(schema_site);
    try writeSiteFile(schema_site, "content/posts/hello.md",
        \\---
        \\.title = "Hello",
        \\.date = "2026-06-27",
        \\.tags = "zig",
        \\---
        \\
        \\# Hello
        \\
    );

    const schema_result = try runZlog(&.{ "check", schema_site });
    defer schema_result.deinit();
    try expectExit(schema_result, 1);
    try expectOutputContains(schema_result, ".tags must be an array of strings");
    try expectOutputContains(schema_result, "hint:");
}

test "cli dev serves the generated site" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const site_path = try tempPath(&tmp.sub_path, "site");
    defer allocator.free(site_path);
    try initSite(site_path);

    const port = try reservePort();
    const port_arg = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_arg);

    try expectDevServes(site_path, port_arg);
}

fn initSite(site_path: []const u8) !void {
    const result = try runZlog(&.{ "init", site_path });
    defer result.deinit();
    try expectExit(result, 0);
}

fn runZlog(args: []const []const u8) !CliResult {
    var argv = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(argv);
    argv[0] = cli_options.zlog_exe;
    @memcpy(argv[1..], args);

    return .{
        .result = try std.process.run(allocator, io, .{
            .argv = argv,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }),
    };
}

fn expectDevServes(site_path: []const u8, port_arg: []const u8) !void {
    var argv = [_][]const u8{ cli_options.zlog_exe, "dev", site_path, port_arg };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{s}/", .{port_arg});
    defer allocator.free(url);
    const body = try waitForHttpOk(url);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Welcome to a zlog site.") != null);
}

fn waitForHttpOk(url: []const u8) ![]u8 {
    var last_stderr: ?[]u8 = null;
    defer if (last_stderr) |stderr| allocator.free(stderr);

    for (0..24) |_| {
        var argv = [_][]const u8{ "curl", "-fsS", "--max-time", "2", url };
        const result = std.process.run(allocator, io, .{
            .argv = &argv,
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(2500), .clock = .boot } },
        }) catch {
            std.Io.Clock.Duration.sleep(.{ .raw = std.Io.Duration.fromMilliseconds(125), .clock = .boot }, io) catch {};
            continue;
        };

        if (last_stderr) |stderr| allocator.free(stderr);
        last_stderr = result.stderr;
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        allocator.free(result.stdout);
        std.Io.Clock.Duration.sleep(.{ .raw = std.Io.Duration.fromMilliseconds(125), .clock = .boot }, io) catch {};
    }

    if (last_stderr) |stderr| {
        std.debug.print("dev server did not respond at {s}\nlast curl stderr:\n{s}\n", .{ url, stderr });
    } else {
        std.debug.print("dev server did not respond at {s}\n", .{url});
    }
    return error.DevServerDidNotServe;
}

fn reservePort() !u16 {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    return server.socket.address.getPort();
}

fn writeSiteFile(site_path: []const u8, rel_path: []const u8, data: []const u8) !void {
    const path = try join(site_path, rel_path);
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn tempPath(sub_path: []const u8, child: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, child });
}

fn join(a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn expectExit(result: CliResult, code: u8) !void {
    switch (result.result.term) {
        .exited => |actual| try std.testing.expectEqual(code, actual),
        else => return error.UnexpectedProcessTerm,
    }
}

fn expectOutputContains(result: CliResult, needle: []const u8) !void {
    if (std.mem.indexOf(u8, result.result.stdout, needle) != null) return;
    if (std.mem.indexOf(u8, result.result.stderr, needle) != null) return;
    std.debug.print("expected command output to contain: {s}\nstdout:\n{s}\nstderr:\n{s}\n", .{ needle, result.result.stdout, result.result.stderr });
    return error.ExpectedOutputMissing;
}
