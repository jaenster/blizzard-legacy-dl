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
        }),
    });
    b.installArtifact(cli);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI: zig build run -- info <downloader.exe>").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = legacy });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
