const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
