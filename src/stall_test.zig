//! A server that answers and then goes silent must not hold a piece fetch past its deadline, on any
//! platform, and the piece must still arrive on a retry against a server that answers.
//! `zig build stall-test` runs it here; `zig build stall-test -Dtarget=x86_64-windows-gnu` installs
//! zig-out/bin/stall-test.exe to run on Windows. STALL_HOST=127.0.0.1 (or a name of this machine)
//! adds the many-pieces run that wedged a worker on Windows; STALL_JOBS sets its worker count.
const std = @import("std");
const installer = @import("installer");
const legacy = @import("legacy");

const body_len = 256 * 1024;

const Mode = enum(u8) {
    /// Read the request, answer nothing.
    silent_before_headers,
    /// Send the headers and part of the body, then nothing.
    silent_mid_body,
    /// Answer the whole body.
    good,
};

const Server = struct {
    listener: std.Io.net.Server,
    port: u16,
    /// What each connection gets, by the order it arrives in; past the end, `good`.
    plan: []const Mode,
    accepted: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn run(s: *Server) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        while (!s.stop.load(.acquire)) {
            const conn = s.listener.accept(io) catch return;
            if (s.stop.load(.acquire)) {
                conn.close(io);
                return;
            }
            const n = s.accepted.fetchAdd(1, .monotonic);
            const mode = if (n < s.plan.len) s.plan[n] else .good;
            // One thread per connection, so a silent one never keeps the next one waiting.
            const t = std.Thread.spawn(.{}, answer, .{ s, conn, mode }) catch {
                conn.close(io);
                continue;
            };
            t.detach();
        }
    }

    fn answer(s: *Server, conn: std.Io.net.Stream, mode: Mode) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        defer conn.close(io);

        // The request, up to its blank line.
        var rbuf: [4096]u8 = undefined;
        var r = conn.reader(io, &rbuf);
        while (true) {
            const line = r.interface.takeDelimiterInclusive('\n') catch return;
            if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), "")) break;
        }

        var wbuf: [4096]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        const body = pattern();
        switch (mode) {
            .silent_before_headers => {},
            .silent_mid_body => {
                w.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body_len}) catch return;
                w.interface.writeAll(body[0..1000]) catch return;
                w.interface.flush() catch return;
            },
            .good => {
                w.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_len}) catch return;
                w.interface.writeAll(body) catch return;
                w.interface.flush() catch return;
                return;
            },
        }
        // Silent, with the connection held open until the test is over.
        while (!s.stop.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(50), .awake) catch return;
    }
};

var pattern_buf: [body_len]u8 = undefined;
fn pattern() []const u8 {
    for (&pattern_buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    return &pattern_buf;
}

fn startServer(io: std.Io, s: *Server, plan: []const Mode) !std.Thread {
    return startServerOn(io, s, plan, "127.0.0.1");
}

fn startServerOn(io: std.Io, s: *Server, plan: []const Mode, bind: []const u8) !std.Thread {
    const addr: std.Io.net.IpAddress = try .parse(bind, 0);
    s.* = .{ .listener = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .plan = plan };
    s.port = s.listener.socket.address.getPort();
    return std.Thread.spawn(.{}, Server.run, .{s});
}

/// Closing a listener under a pending accept is not allowed on Windows: wake the accept with a
/// connection of its own, and close the listener once its thread is gone.
fn stopServer(io: std.Io, s: *Server, t: std.Thread) void {
    s.stop.store(true, .release);
    const addr: std.Io.net.IpAddress = std.Io.net.IpAddress.parse("127.0.0.1", s.port) catch unreachable;
    if (addr.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
    t.join();
    s.listener.deinit(io);
}

var current_server: ?*Server = null;

/// Kills the test process if a fetch outlives any reasonable deadline, so a hang is a failure and
/// not a test run that never ends.
fn watchdog(done: *std.atomic.Value(bool), what: []const u8) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var waited: usize = 0;
    while (!done.load(.acquire)) : (waited += 1) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        if (waited == 450) {
            std.debug.print("HANG: {s} still running after 45 s, {d} connections accepted\n", .{ what, if (current_server) |cs| cs.accepted.load(.monotonic) else 0 });
            if (@import("builtin").os.tag == .windows) dumpThreads();
            std.process.exit(3);
        }
    }
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn expectTimeout(mode: Mode) !void {
    var threaded: std.Io.Threaded = undefined;
    installer.workerIo(&threaded);
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = undefined;
    const plan = [_]Mode{mode};
    const st = try startServer(io, &server, &plan);
    defer {
        stopServer(io, &server, st);
    }

    var done: std.atomic.Value(bool) = .init(false);
    const wd = try std.Thread.spawn(.{}, watchdog, .{ &done, @tagName(mode) });
    defer {
        done.store(true, .release);
        wd.join();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();

    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/0", .{server.port});
    const t0 = nowMs(io);
    const got = installer.fetchWithin(arena.allocator(), io, &client, url, null, 2000);
    const took = nowMs(io) - t0;
    std.debug.print("{t}: {any} after {d} ms\n", .{ mode, if (got) |_| @as(anyerror, error.GotABody) else |e| e, took });
    try std.testing.expectError(error.Timeout, got);
    try std.testing.expect(took >= 1900 and took < 6000);
}

test "a server that goes silent before its headers times the fetch out" {
    try expectTimeout(.silent_before_headers);
}

test "a server that goes silent mid-body times the fetch out" {
    try expectTimeout(.silent_mid_body);
}

/// A one-piece payload of `pattern()` whose only mirror is the test server, fetched into a fresh directory.
fn fetchOnePiece(plan: []const Mode, retries: usize, timeout_ms: u64) !struct { installer.FetchResult, usize, i64 } {
    return fetchPieces(plan, retries, timeout_ms, 1, "127.0.0.1", 1);
}

/// `count` pieces, every one of them `pattern()`, from `host` (which must resolve to this machine).
fn fetchPieces(plan: []const Mode, retries: usize, timeout_ms: u64, count: usize, host: []const u8, jobs: usize) !struct { installer.FetchResult, usize, i64 } {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server: Server = undefined;
    current_server = &server;
    defer current_server = null;
    const st = try startServerOn(io, &server, plan, if (std.mem.eql(u8, host, "127.0.0.1")) "127.0.0.1" else "0.0.0.0");
    defer {
        stopServer(io, &server, st);
    }
    var done: std.atomic.Value(bool) = .init(false);
    const wd = try std.Thread.spawn(.{}, watchdog, .{ &done, "fetchPayload" });
    defer {
        done.store(true, .release);
        wd.join();
    }

    var d: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(pattern(), &d, .{});
    var t: std.Io.Writer.Allocating = .init(gpa);
    const w = &t.writer;
    try w.print("d8:announce{d}:{s}", .{ "http://tracker.invalid/announce".len, "http://tracker.invalid/announce" });
    try w.print("15:direct download{d}:{s}", .{ "http://127.0.0.1/x".len, "http://127.0.0.1/x" });
    try w.print("4:infod5:filesld6:lengthi{d}e4:pathl9:piece.binee", .{body_len * count});
    try w.print("e4:name5:Stall12:piece lengthi{d}e6:pieces{d}:", .{ body_len, 20 * count });
    for (0..count) |_| try w.writeAll(&d);
    try w.writeAll("ee");
    var meta = try legacy.fromStub(gpa, t.written());
    var mirrors = [_]legacy.Server{.{ .url = try std.fmt.allocPrint(gpa, "http://{s}:{d}", .{ host, server.port }) }};
    meta.servers = &mirrors;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    const dest = try std.fs.path.join(gpa, &.{ root, "Stall" });
    try installer.preallocate(gpa, io, meta, dest);

    var rep: installer.Reporter = .init(null);
    const t0 = nowMs(io);
    const res = try installer.fetchPayload(gpa, io, meta, dest, .{
        .retries = retries,
        .jobs = jobs,
        .piece_timeout_ms = timeout_ms,
    }, &rep);
    const took = nowMs(io) - t0;
    if (res.done == 1 and count == 1) {
        const path = try std.fs.path.join(gpa, &.{ dest, "piece.bin" });
        const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        try std.testing.expectEqualSlices(u8, pattern(), got);
    }
    return .{ res, server.accepted.load(.monotonic), took };
}

test "a piece whose first two connections go silent arrives on a retry" {
    const res, const conns, const took = try fetchOnePiece(&.{ .silent_mid_body, .silent_before_headers }, 3, 1500);
    std.debug.print("retry: done {d} failed {d}, {d} connections, {d} ms\n", .{ res.done, res.failed, conns, took });
    try std.testing.expectEqual(@as(usize, 1), res.done);
    try std.testing.expectEqual(@as(usize, 0), res.failed);
    try std.testing.expectEqual(@as(usize, 3), conns);
    try std.testing.expect(took < 15_000);
}

test "a piece whose every connection goes silent fails once its retries are spent" {
    const res, const conns, const took = try fetchOnePiece(&.{ .silent_mid_body, .silent_mid_body, .silent_mid_body }, 1, 1500);
    std.debug.print("give up: done {d} failed {d}, {d} connections, {d} ms\n", .{ res.done, res.failed, conns, took });
    try std.testing.expectEqual(@as(usize, 0), res.done);
    try std.testing.expectEqual(@as(usize, 1), res.failed);
    try std.testing.expectEqual(@as(usize, 2), conns);
    try std.testing.expect(took < 15_000);
}

test "400 pieces over four workers, a fresh connection for each, never wedge a worker (STALL_HOST)" {
    const host = std.c.getenv("STALL_HOST") orelse return error.SkipZigTest;
    const jobs = if (std.c.getenv("STALL_JOBS")) |j| try std.fmt.parseInt(usize, std.mem.span(j), 10) else 4;
    const res, const conns, const took = try fetchPieces(&.{}, 3, 5000, 400, std.mem.span(host), jobs);
    std.debug.print("many: done {d} failed {d}, {d} connections, {d} ms\n", .{ res.done, res.failed, conns, took });
    try std.testing.expectEqual(@as(usize, 400), res.done);
}

// Every other thread's stack, for a hang on Windows where there is no debugger to ask.
const win = std.os.windows;
const THREADENTRY32 = extern struct { dwSize: u32, cntUsage: u32, th32ThreadID: u32, th32OwnerProcessID: u32, tpBasePri: i32, tpDeltaPri: i32, dwFlags: u32 };
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) win.HANDLE;
extern "kernel32" fn Thread32First(h: win.HANDLE, e: *THREADENTRY32) callconv(.winapi) win.BOOL;
extern "kernel32" fn Thread32Next(h: win.HANDLE, e: *THREADENTRY32) callconv(.winapi) win.BOOL;
extern "kernel32" fn OpenThread(access: u32, inherit: win.BOOL, id: u32) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SuspendThread(h: win.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetThreadContext(h: win.HANDLE, c: *win.CONTEXT) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

fn dumpThreads() void {
    const snap = CreateToolhelp32Snapshot(4, 0);
    var e: THREADENTRY32 = undefined;
    e.dwSize = @sizeOf(THREADENTRY32);
    const me = GetCurrentProcessId();
    const self = GetCurrentThreadId();
    var ok = Thread32First(snap, &e);
    while (ok.toBool()) : (ok = Thread32Next(snap, &e)) {
        if (e.th32OwnerProcessID != me or e.th32ThreadID == self) continue;
        const h = OpenThread(0x1FFFFF, .FALSE, e.th32ThreadID) orelse continue;
        _ = SuspendThread(h);
        var ctx: win.CONTEXT align(16) = std.mem.zeroes(win.CONTEXT);
        ctx.ContextFlags = 0x10000B; // CONTEXT_FULL
        if (!GetThreadContext(h, &ctx).toBool()) continue;
        var addrs: [48]usize = undefined;
        var n: usize = 0;
        while (n < addrs.len and ctx.Rip != 0) {
            addrs[n] = ctx.Rip;
            n += 1;
            var base: usize = 0;
            var history: win.UNWIND_HISTORY_TABLE = std.mem.zeroes(win.UNWIND_HISTORY_TABLE);
            if (win.ntdll.RtlLookupFunctionEntry(ctx.Rip, &base, &history)) |fe| {
                var handler: ?*anyopaque = null;
                var frame: usize = 0;
                _ = win.ntdll.RtlVirtualUnwind(0, base, ctx.Rip, fe, &ctx, &handler, &frame, null);
            } else {
                ctx.Rip = @as(*const usize, @ptrFromInt(ctx.Rsp)).*;
                ctx.Rsp += 8;
            }
        }
        const trace: std.debug.StackTrace = .{ .return_addresses = addrs[0..n], .skipped = .none };
        const t = std.debug.lockStderr(&.{}).terminal();
        defer std.debug.unlockStderr();
        t.writer.print("\n--- thread {d}\n", .{e.th32ThreadID}) catch {};
        std.debug.writeStackTrace(&trace, t) catch {};
    }
}
