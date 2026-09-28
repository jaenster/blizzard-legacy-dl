//! A deadline for one HTTP request at a time, kept by a thread of its own. When the request runs
//! past it, its connection is disconnected, which ends a read waiting on a server that went quiet.
//!
//! This deliberately uses no `std.Io` task, select or cancelation: on Windows, Zig 0.16's
//! `Io.Threaded` can lose the wakeup of its internal parking mutex, and a thread waiting on a
//! cancelled task then never returns. The requests themselves should run on an `Io` that keeps
//! everything on the calling thread (`singleThreaded`); the watchdog touches only the socket.
const std = @import("std");
const builtin = @import("builtin");

/// An `Io.Threaded` that runs nothing on other threads: no async task and no concurrency.
pub fn singleThreaded(threaded: *std.Io.Threaded, gpa: std.mem.Allocator) void {
    threaded.* = .init(gpa, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
}

pub const Watch = struct {
    lock: std.atomic.Value(bool) = .init(false),
    stream: ?std.Io.net.Stream = null,
    /// Milliseconds on the `.awake` clock; 0 while nothing is watched.
    deadline_ms: std.atomic.Value(i64) = .init(0),
    timeout_ms: std.atomic.Value(u64) = .init(0),
    expired: std.atomic.Value(bool) = .init(false),
    stop_flag: std.atomic.Value(bool) = .init(false),

    /// The watchdog thread, until `stop`.
    pub fn start(w: *Watch) !std.Thread {
        w.stop_flag.store(false, .release);
        return std.Thread.spawn(.{}, run, .{w});
    }

    pub fn stop(w: *Watch, t: std.Thread) void {
        w.stop_flag.store(true, .release);
        t.join();
    }

    /// Start watching: the request must finish (or `touch` again) within `timeout_ms`.
    pub fn begin(w: *Watch, io: std.Io, timeout_ms: u64) void {
        w.expired.store(false, .release);
        w.timeout_ms.store(timeout_ms, .release);
        w.touch(io);
    }

    /// Move the deadline to `timeout_ms` from now: for a deadline on silence rather than on the whole request.
    pub fn touch(w: *Watch, io: std.Io) void {
        w.deadline_ms.store(nowMs(io) + @as(i64, @intCast(w.timeout_ms.load(.acquire))), .release);
    }

    /// Stop the clock without ending the request (while it is paused on purpose); `touch` restarts it.
    pub fn hold(w: *Watch) void {
        w.deadline_ms.store(0, .release);
    }

    /// Stop watching. Whether the request ran past its deadline.
    pub fn end(w: *Watch) bool {
        w.deadline_ms.store(0, .release);
        return w.expired.load(.acquire);
    }

    /// The connection the request reads from, once it is open.
    pub fn attach(w: *Watch, stream: std.Io.net.Stream) void {
        w.acquire();
        defer w.release();
        w.stream = stream;
    }

    /// After this the watchdog no longer touches the socket, so it may be closed or reused.
    pub fn detach(w: *Watch) void {
        w.acquire();
        defer w.release();
        w.stream = null;
    }

    fn acquire(w: *Watch) void {
        while (w.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(w: *Watch) void {
        w.lock.store(false, .release);
    }

    fn run(w: *Watch) void {
        var threaded: std.Io.Threaded = undefined;
        singleThreaded(&threaded, std.heap.page_allocator);
        defer threaded.deinit();
        const io = threaded.io();
        while (!w.stop_flag.load(.acquire)) {
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
            const d = w.deadline_ms.load(.acquire);
            if (d == 0 or nowMs(io) < d or w.expired.load(.acquire)) continue;
            w.expired.store(true, .release);
            w.acquire();
            defer w.release();
            if (w.stream) |s| abortConnection(io, s);
        }
    }
};

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

/// End every read and write waiting on `s`. A POSIX shutdown does that; on Windows only an abortive
/// disconnect does (a graceful one leaves a pending receive waiting), and closing the socket instead
/// would complete the receive as cancelled, which Zig's reader treats as impossible.
pub fn abortConnection(io: std.Io, s: std.Io.net.Stream) void {
    if (builtin.os.tag != .windows) {
        s.shutdown(io, .both) catch {};
        return;
    }
    const windows = std.os.windows;
    const ev = CreateEventW(null, .TRUE, .FALSE, null) orelse return;
    defer windows.CloseHandle(ev);
    // Kept alive past a wait that times out: the driver may still write it.
    const iosb = std.heap.page_allocator.create(windows.IO_STATUS_BLOCK) catch return;
    var info: windows.AFD.PARTIAL_DISCONNECT_INFO = .{
        .DisconnectMode = .{ .SEND = true, .RECEIVE = true, .ABORTIVE = true },
        .Timeout = -1,
    };
    const st = windows.ntdll.NtDeviceIoControlFile(s.socket.handle, ev, null, null, iosb, windows.IOCTL.AFD.PARTIAL_DISCONNECT, &info, @sizeOf(@TypeOf(info)), null, 0);
    if (st == .PENDING and WaitForSingleObject(ev, 5000) != 0) return; // leave `iosb` to the driver
    std.heap.page_allocator.destroy(iosb);
}

extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: std.os.windows.BOOL, initial: std.os.windows.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(h: std.os.windows.HANDLE, ms: u32) callconv(.winapi) u32;
