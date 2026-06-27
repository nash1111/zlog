const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_version = "0.1.0";

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkMarkdownParser(root_module);

    const exe = b.addExecutable(.{
        .name = "zlog",
        .root_module = root_module,
    });
    b.installArtifact(exe);
    addReleaseLocalStep(b, target, release_version);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run zlog");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);

    const cli_test_options = b.addOptions();
    cli_test_options.addOptionPath("zlog_exe", exe.getEmittedBin());
    const cli_tests_module = b.createModule(.{
        .root_source_file = b.path("test/cli_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests_module.addOptions("cli_test_options", cli_test_options);
    const cli_tests = b.addTest(.{
        .root_module = cli_tests_module,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}

fn linkMarkdownParser(module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("cmark-gfm", .{});
    module.linkSystemLibrary("cmark-gfm-extensions", .{});
}

fn addReleaseLocalStep(b: *std.Build, target: std.Build.ResolvedTarget, version: []const u8) void {
    const release_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    linkMarkdownParser(release_module);

    const release_exe = b.addExecutable(.{
        .name = "zlog",
        .root_module = release_module,
    });

    const target_name = b.fmt("{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
    });
    const artifact_name = b.fmt("zlog-{s}-{s}", .{ version, target_name });
    const release_dir = b.fmt("releases/{s}", .{artifact_name});

    const install_bin = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = release_dir } },
        .dest_sub_path = "zlog",
    });
    const install_readme = b.addInstallFileWithDir(b.path("README.md"), .{ .custom = release_dir }, "README.md");
    const install_release_notes = b.addInstallFileWithDir(b.path("docs/releases.md"), .{ .custom = release_dir }, "RELEASES.md");

    const archive_path = b.fmt("zig-out/releases/{s}.tar.gz", .{artifact_name});
    const archive = b.addSystemCommand(&.{ "tar", "-czf", archive_path, "-C", "zig-out/releases", artifact_name });
    archive.step.dependOn(&install_bin.step);
    archive.step.dependOn(&install_readme.step);
    archive.step.dependOn(&install_release_notes.step);

    const release_step = b.step("release-local", "Build the local release directory and tarball");
    release_step.dependOn(&archive.step);
}
