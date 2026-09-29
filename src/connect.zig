//! Finding an address of a host that answers, on a machine where some of its addresses do not.
//!
//! The installer keeps every request on one thread (see watch.zig), and with that the standard library
//! tries a host's addresses one after another, each for as long as the operating system waits for a
//! connect: 21 seconds on Windows. One dead address, typically an IPv6 route that goes nowhere, costs
//! that much every time, and when it is the only one tried, the whole request fails. Here each address
//! is tried on a thread of its own (a plain `std.Thread`, no `Io` task), IPv4 first and the next one a
//! moment later, and the first to answer wins; the request then goes to that address.
const std = @import("std");
const net = std.Io.net;

pub const max_addresses = 8;

/// How long to let one address hold the others back before the next is tried alongside it.
pub const stagger_ms = 250;
/// How long to wait for any address at all.
pub const give_up_ms = 8000;

pub const Result = enum(u8) { pending, connected, failed };

const Attempt = struct {
    address: net.IpAddress,
    result: std.atomic.Value(Result) = .init(.pending),
    started: std.atomic.Value(bool) = .init(false),
    err: [40]u8 = @splat(0),
    err_len: u8 = 0,
    ms: u32 = 0,
};

/// Shared between the caller and the attempt threads, which may outlive the call: whoever drops the last
/// reference frees it.
const Shared = struct {
    refs: std.atomic.Value(u32),
    winner: std.atomic.Value(i32) = .init(-1),
    count: usize,
    attempts: [max_addresses]Attempt,

    fn release(s: *Shared) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) std.heap.page_allocator.destroy(s);
    }
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn attemptThread(s: *Shared, i: usize) void {
    defer s.release();
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(std.heap.page_allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const a = &s.attempts[i];
    const t0 = nowMs(io);
    if (a.address.connect(io, .{ .mode = .stream })) |stream| {
        a.ms = @intCast(@max(0, nowMs(io) - t0));
        // The request opens its own connection to the winner; this one only proved the address answers.
        stream.close(io);
        _ = s.winner.cmpxchgStrong(-1, @intCast(i), .acq_rel, .acquire);
        a.result.store(.connected, .release);
    } else |e| {
        a.ms = @intCast(@max(0, nowMs(io) - t0));
        const name = @errorName(e);
        a.err_len = @intCast(@min(name.len, a.err.len));
        @memcpy(a.err[0..a.err_len], name[0..a.err_len]);
        a.result.store(.failed, .release);
    }
}

/// IPv4 addresses ahead of IPv6, each family in the order given.
pub fn ordered(addrs: []const net.IpAddress, out: []net.IpAddress) []net.IpAddress {
    var n: usize = 0;
    for (addrs) |a| if (a == .ip4 and n < out.len) {
        out[n] = a;
        n += 1;
    };
    for (addrs) |a| if (a == .ip6 and n < out.len) {
        out[n] = a;
        n += 1;
    };
    return out[0..n];
}

/// An address as text without its port or brackets, the way a host name field wants it.
pub fn literal(a: net.IpAddress, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    a.format(&w) catch return "";
    const s = w.buffered();
    const end = std.mem.lastIndexOfScalar(u8, s, ':') orelse return s;
    const text = s[0..end];
    return if (text.len >= 2 and text[0] == '[') text[1 .. text.len - 1] else text;
}

/// What each address did, one line, for the log.
pub const Note = struct {
    buf: [480]u8 = undefined,
    len: usize = 0,
    /// Some address failed or was slow: worth a line even when the request went through.
    trouble: bool = false,

    pub fn text(n: *const Note) []const u8 {
        return n.buf[0..n.len];
    }
};

pub threadlocal var last_note: Note = .{};

/// Try `addrs` (in the order given) and return the first that connects.
pub fn race(io: std.Io, addrs: []const net.IpAddress, stagger: u64, give_up: u64) !net.IpAddress {
    last_note = .{};
    if (addrs.len == 0) return error.UnknownHostName;
    const s = try std.heap.page_allocator.create(Shared);
    const count = @min(addrs.len, max_addresses);
    s.* = .{ .refs = .init(1), .count = count, .attempts = undefined };
    for (0..count) |i| s.attempts[i] = .{ .address = addrs[i] };
    defer s.release();

    const t0 = nowMs(io);
    var next: usize = 0;
    var last_start: i64 = 0;
    var launched: usize = 0;
    var won: ?usize = null;
    while (true) {
        const now = nowMs(io);
        const w = s.winner.load(.acquire);
        if (w >= 0) {
            won = @intCast(w);
            break;
        }
        // The next address goes when the ones so far are all down, or the stagger has passed.
        var all_down = launched > 0;
        for (0..launched) |i| if (s.attempts[i].result.load(.acquire) != .failed) {
            all_down = false;
        };
        if (next < count and (launched == 0 or all_down or now - last_start >= @as(i64, @intCast(stagger)))) {
            s.attempts[next].started.store(true, .release);
            _ = s.refs.fetchAdd(1, .monotonic);
            if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, attemptThread, .{ s, next })) |t| {
                t.detach();
            } else |_| {
                s.attempts[next].result.store(.failed, .release);
                s.release();
            }
            next += 1;
            launched = next;
            last_start = now;
            continue;
        }
        if (next >= count and all_down) break;
        if (now - t0 >= @as(i64, @intCast(give_up))) break;
        std.Io.sleep(io, .fromMilliseconds(15), .awake) catch {};
    }

    // The notes: every address that has been tried and what came of it.
    var w = std.Io.Writer.fixed(&last_note.buf);
    for (0..launched) |i| {
        const a = &s.attempts[i];
        var ab: [64]u8 = undefined;
        const lit = literal(a.address, &ab);
        const r = a.result.load(.acquire);
        switch (r) {
            .connected => w.print("{s} ok in {d} ms; ", .{ lit, a.ms }) catch {},
            .failed => {
                w.print("{s} {s} after {d} ms; ", .{ lit, a.err[0..a.err_len], a.ms }) catch {};
                last_note.trouble = true;
            },
            .pending => {
                w.print("{s} no answer in {d} ms; ", .{ lit, @max(0, nowMs(io) - t0) }) catch {};
                last_note.trouble = true;
            },
        }
    }
    last_note.len = w.buffered().len;
    if (won) |i| {
        if (i > 0) last_note.trouble = true;
        return s.attempts[i].address;
    }
    // All of them failed, or none answered in time: the first failure's name, else a timeout.
    for (0..launched) |i| if (s.attempts[i].result.load(.acquire) == .failed) {
        const name = s.attempts[i].err[0..s.attempts[i].err_len];
        if (std.mem.eql(u8, name, "ConnectionRefused")) return error.ConnectionRefused;
        if (std.mem.eql(u8, name, "NetworkUnreachable")) return error.NetworkUnreachable;
        if (std.mem.eql(u8, name, "HostUnreachable")) return error.HostUnreachable;
    };
    return error.ConnectionTimedOut;
}

/// The addresses of `host`, IPv4 first.
pub fn resolve(io: std.Io, host: []const u8, port: u16, out: []net.IpAddress) ![]net.IpAddress {
    if (net.IpAddress.parse(host, port)) |one| {
        out[0] = one;
        return out[0..1];
    } else |_| {}
    const name = try net.HostName.init(host);
    var buf: [32]net.HostName.LookupResult = undefined;
    var q: std.Io.Queue(net.HostName.LookupResult) = .init(&buf);
    try name.lookup(io, &q, .{ .port = port });
    var found: [32]net.IpAddress = undefined;
    var n: usize = 0;
    while (q.getOne(io)) |r| switch (r) {
        .address => |a| if (n < found.len) {
            found[n] = a;
            n += 1;
        },
        .canonical_name => {},
    } else |_| {}
    if (n == 0) return error.UnknownHostName;
    return ordered(found[0..n], out);
}

const testing = std.testing;

test "IPv4 goes ahead of IPv6, each in the order the resolver gave" {
    const a = [_]net.IpAddress{
        net.IpAddress.parse("2a02:26f0:1180:71::210:6a08", 443) catch unreachable,
        net.IpAddress.parse("95.101.74.217", 443) catch unreachable,
        net.IpAddress.parse("2a02:26f0:1180:71::210:6a09", 443) catch unreachable,
        net.IpAddress.parse("95.101.74.218", 443) catch unreachable,
    };
    var out: [8]net.IpAddress = undefined;
    const o = ordered(&a, &out);
    try testing.expectEqual(@as(usize, 4), o.len);
    try testing.expect(o[0] == .ip4 and o[1] == .ip4 and o[2] == .ip6 and o[3] == .ip6);
    try testing.expectEqual(@as(u8, 217), o[0].ip4.bytes[3]);
    try testing.expectEqual(@as(u8, 218), o[1].ip4.bytes[3]);
}

test "an address as text, without port or brackets" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("95.101.74.217", literal(net.IpAddress.parse("95.101.74.217", 443) catch unreachable, &buf));
    try testing.expectEqualStrings("::1", literal(net.IpAddress.parse("::1", 443) catch unreachable, &buf));
}

test "a listening address wins over one that never answers" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    const good = server.socket.address;
    // Nothing listens here: refused at once on a machine with a loopback, so the good address is second.
    var bad = good;
    bad.ip4.port = if (good.ip4.port == 1) 2 else 1;
    const got = try race(io, &.{ bad, good }, 50, 3000);
    try testing.expectEqual(good.ip4.port, got.ip4.port);
    try testing.expect(std.mem.indexOf(u8, last_note.text(), "ok in") != null);
}

test "when nothing answers the failure is an error, not a hang" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    var dead = server.socket.address;
    server.deinit(io);
    dead.ip4.port = if (dead.ip4.port == 1) 2 else 1;
    try testing.expectError(error.ConnectionRefused, race(io, &.{dead}, 50, 3000));
}
