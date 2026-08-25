const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the library, importable by other projects:
    // `.imports = &.{ .{ .name = "legacy", .module = dep } }`
    const legacy = b.addModule("legacy", .{
        .root_source_file = b.path("src/legacy.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli = b.addExecutable(.{
        .name = "blizzard-legacy-dl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "legacy", .module = legacy }},
            // the file IO goes through libc: std.fs is reworked under 0.16's Io interface
            .link_libc = true,
        }),
    });
    b.installArtifact(cli);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI: zig build run -- info <downloader.exe>").dependOn(&run.step);

    const test_step = b.step("test", "Run the tests");

    const tests = b.addTest(.{ .root_module = legacy });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // fetch, verify and reassembly against a payload built and served on the spot
    const e2e = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "legacy", .module = legacy }},
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(e2e).step);
}
