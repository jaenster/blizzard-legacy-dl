//! Compiled for x86_64-windows-gnu by `zig build check-windows`: the calls a launcher makes into
//! the "installer" module, so a change that breaks the Windows build of an embedder shows up here.
const std = @import("std");
const installer = @import("installer");

fn onProgress(ctx: ?*anyopaque, ev: installer.Event) void {
    const seen: *u64 = @ptrCast(@alignCast(ctx.?));
    seen.* = ev.done;
    _ = ev.stage;
    _ = ev.message;
}

pub export fn launcherInstall(game_dir: [*:0]const u8) c_int {
    var seen: u64 = 0;
    var control: installer.Control = .{};
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    installer.install(std.heap.smp_allocator, threaded.io(), .{
        .game_dir = std.mem.span(game_dir),
        .progress = .{ .ctx = &seen, .report = onProgress },
        .control = &control,
    }) catch |e| return switch (e) {
        error.Cancelled => 1,
        else => 2,
    };
    return 0;
}
