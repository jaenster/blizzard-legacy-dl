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

    // A request deadline kept on the socket by a thread of its own, for any HTTP client in an embedder:
    // `.imports = &.{ .{ .name = "watch", .module = dep.module("watch") } }`
    const watch = b.addModule("watch", .{
        .root_source_file = b.path("src/watch.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Connecting to whichever address of a host answers, for any std.http.Client in an embedder (a host with a dead
    // IPv6 route otherwise costs the operating system's whole connect wait): `dep.module("connect")`.
    const connect = b.addModule("connect", .{
        .root_source_file = b.path("src/connect.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The installer half needs the MPQ reader and the install-script reader, both of which
    // live in libd2 rather than being carried a second time here.
    const libd2 = b.dependency("libd2", .{ .target = target, .optimize = optimize });

    // The install pipeline, for a program that embeds it instead of running the CLI:
    // `.imports = &.{ .{ .name = "installer", .module = dep.module("installer") } }`
    const installer = b.addModule("installer", .{
        .root_source_file = b.path("src/installer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "legacy", .module = legacy },
            .{ .name = "libd2", .module = libd2.module("libd2") },
            .{ .name = "watch", .module = watch },
            .{ .name = "connect", .module = connect },
        },
        .link_libc = true,
    });

    const cli = b.addExecutable(.{
        .name = "blizzard-legacy-dl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "legacy", .module = legacy },
                .{ .name = "libd2", .module = libd2.module("libd2") },
                .{ .name = "watch", .module = watch },
                .{ .name = "connect", .module = connect },
            .{ .name = "connect", .module = connect },
            },
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

    const cli_tests = b.addTest(.{ .root_module = cli.root_module });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // the installer's own archive surgery, over archives built in memory
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = connect })).step);

    const installer_tests = b.addTest(.{ .root_module = installer });
    test_step.dependOn(&b.addRunArtifact(installer_tests).step);

    // fetch, verify and reassembly against a payload built and served on the spot
    const e2e = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "legacy", .module = legacy },
            .{ .name = "installer", .module = installer },
            .{ .name = "libd2", .module = libd2.module("libd2") },
        },
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(e2e).step);

    // A server that goes silent mid-piece: the fetch must give up on time and retry, here and on Windows.
    // With -Dtarget for another OS it installs zig-out/bin/stall-test(.exe) instead of running.
    const stall = b.addTest(.{
        .name = "stall-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stall_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "installer", .module = installer }, .{ .name = "legacy", .module = legacy } },
            .link_libc = true,
        }),
        .filters = if (b.option([]const u8, "stall-filter", "Only the stall tests whose name contains this")) |f| b.dupeStrings(&.{f}) else &.{},
    });
    const stall_step = b.step("stall-test", "Fetch against a server that goes silent (installs the exe when cross-compiling)");
    if (target.result.os.tag == b.graph.host.result.os.tag)
        stall_step.dependOn(&b.addRunArtifact(stall).step)
    else
        stall_step.dependOn(&b.addInstallArtifact(stall, .{}).step);

    // A program embedding the "installer" module must build for Windows, whatever the host.
    const embed = b.addObject(.{
        .name = "installer-embed-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/embed_check.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }),
            .optimize = optimize,
            .imports = &.{.{ .name = "installer", .module = installerFor(b, .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, optimize) }},
            .link_libc = true,
        }),
    });
    const check_windows = b.step("check-windows", "Compile a program that embeds the installer module, for x86_64-windows-gnu");
    check_windows.dependOn(&embed.step);
    test_step.dependOn(check_windows);
}

/// The installer module built for a target other than the one given on the command line.
fn installerFor(b: *std.Build, query: std.Target.Query, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const target = b.resolveTargetQuery(query);
    const libd2 = b.dependency("libd2", .{ .target = target, .optimize = optimize });
    const legacy = b.createModule(.{
        .root_source_file = b.path("src/legacy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const watch = b.createModule(.{
        .root_source_file = b.path("src/watch.zig"),
        .target = target,
        .optimize = optimize,
    });
    const connect = b.createModule(.{
        .root_source_file = b.path("src/connect.zig"),
        .target = target,
        .optimize = optimize,
    });
    return b.createModule(.{
        .root_source_file = b.path("src/installer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "legacy", .module = legacy },
            .{ .name = "libd2", .module = libd2.module("libd2") },
            .{ .name = "watch", .module = watch },
            .{ .name = "connect", .module = connect },
        },
        .link_libc = true,
    });
}
