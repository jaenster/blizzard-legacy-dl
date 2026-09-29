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
/// How long to wait for any address at all: past it the request fails with error.ConnectionTimedOut and the caller's
/// own retry with backoff takes over, rather than the operating system's 21 s wait for one family.
pub const give_up_ms = 6000;

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

/// IPv6 and IPv4 addresses alternating, IPv6 first, each family in the order given (RFC 8305): a family that
/// goes nowhere is never the only one tried.
pub fn ordered(addrs: []const net.IpAddress, out: []net.IpAddress) []net.IpAddress {
    var n: usize = 0;
    var ix6: usize = 0;
    var ix4: usize = 0;
    var want6 = true;
    while (n < out.len) {
        while (ix6 < addrs.len and addrs[ix6] != .ip6) ix6 += 1;
        while (ix4 < addrs.len and addrs[ix4] != .ip4) ix4 += 1;
        const have6 = ix6 < addrs.len;
        const have4 = ix4 < addrs.len;
        if (!have6 and !have4) break;
        if ((want6 and have6) or !have4) {
            out[n] = addrs[ix6];
            ix6 += 1;
        } else {
            out[n] = addrs[ix4];
            ix4 += 1;
        }
        n += 1;
        want6 = !want6;
    }
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

/// A connection to `uri`'s host for `client`: one it already holds, else one to whichever of the host's addresses
/// answers first, verified as the host itself (the address only says where to connect; the certificate and the
/// Host header are the name's). Pass it as `RequestOptions.connection`, or use `warm` for a client that fetches.
pub fn open(client: *std.http.Client, uri: std.Uri) !*std.http.Client.Connection {
    return (try openTracked(client, uri)).connection;
}

/// A connection and whether it came out of the client's pool (one that had been idle) rather than being dialled now.
pub const Opened = struct { connection: *std.http.Client.Connection, reused: bool };

/// `open`, saying whether the connection was reused. Connections that sat idle for `idle_limit_ms` are dropped
/// first: a server, a load balancer or a NAT closes those without a word, and the request that finds the dead
/// one fails with HttpConnectionClosing.
pub fn openTracked(client: *std.http.Client, uri: std.Uri) !Opened {
    const io = client.io;
    if (idleExpired(client, io)) dropIdle(client);
    touch(client, io);
    var name_buf: [net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&name_buf);
    const protocol: std.http.Client.Protocol = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) .tls else .plain;
    // The certificate roots, loaded once per client, as `Client.request` does before it connects.
    if (protocol == .tls) tls: {
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) break :tls;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.CertificateBundleLoadFailure,
        };
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }
    const port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80);
    if (client.connection_pool.findConnection(io, .{ .host = host, .port = port, .protocol = protocol })) |c| return .{ .connection = c, .reused = true };
    var found: [32]net.IpAddress = undefined;
    const addrs = try resolve(io, host.bytes, port, &found);
    // One address leaves nothing to choose between: the ordinary connect.
    if (addrs.len == 1) return .{ .connection = try client.connectTcpOptions(.{ .host = host, .port = port, .protocol = protocol }), .reused = false };
    const winner = try race(io, addrs, stagger_ms, give_up_ms);
    var lit: [64]u8 = undefined;
    return .{ .connection = try client.connectTcpOptions(.{
        .host = .{ .bytes = literal(winner, &lit) },
        .port = port,
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    }), .reused = false };
}

/// Opens a connection to `url`'s host the way `open` does and leaves it in the client's pool, so the `fetch` or
/// `request` that follows picks it up instead of connecting the standard way.
pub fn warm(client: *std.http.Client, url: []const u8) !void {
    _ = try warmTracked(client, try std.Uri.parse(url));
}

/// `warm`, saying whether the connection it left in the pool was an idle one reused.
fn warmTracked(client: *std.http.Client, uri: std.Uri) !bool {
    const o = try openTracked(client, uri);
    client.connection_pool.release(o.connection, client.io);
    return o.reused;
}

/// How long a pooled connection may sit idle before it is not trusted any more.
pub var idle_limit_ms: i64 = 30_000;

/// Requests that failed on a reused connection and went again on a fresh one.
pub var stale_retries: std.atomic.Value(u32) = .init(0);

// When each client last opened or finished a request, by address; a small table, since a program has a few clients.
const activity_slots = 8;
var activity_keys: [activity_slots]std.atomic.Value(usize) = @splat(.init(0));
var activity_ms: [activity_slots]std.atomic.Value(i64) = @splat(.init(0));

fn slotOf(client: *std.http.Client) usize {
    const key = @intFromPtr(client);
    for (&activity_keys, 0..) |*k, i| {
        if (k.load(.acquire) == key) return i;
    }
    for (&activity_keys, 0..) |*k, i| {
        if (k.cmpxchgStrong(0, key, .acq_rel, .acquire) == null) return i;
    }
    // Full: a slot is taken over; its client merely loses its history and is treated as fresh.
    const i = (key >> 4) % activity_slots;
    activity_keys[i].store(key, .release);
    activity_ms[i].store(0, .release);
    return i;
}

fn touch(client: *std.http.Client, io: std.Io) void {
    activity_ms[slotOf(client)].store(nowMs(io), .release);
}

fn idleExpired(client: *std.http.Client, io: std.Io) bool {
    const last = activity_ms[slotOf(client)].load(.acquire);
    return last != 0 and nowMs(io) - last > idle_limit_ms;
}

/// Closes every connection the client holds idle in its pool, so the next request dials anew.
pub fn dropIdle(client: *std.http.Client) void {
    const io = client.io;
    const pool = &client.connection_pool;
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    while (pool.free.popFirst()) |node| {
        const c: *std.http.Client.Connection = @alignCast(@fieldParentPtr("pool_node", node));
        pool.free_len -= 1;
        c.destroy(io);
    }
}

/// A failure that says a reused connection was dead already: the server closed it while it sat idle.
pub fn isStale(e: anyerror) bool {
    return switch (e) {
        error.HttpConnectionClosing, error.ConnectionResetByPeer, error.EndOfStream, error.BrokenPipe, error.ReadFailed, error.WriteFailed => true,
        else => false,
    };
}

/// `client.fetch` over `open`'s connection choice, with one retry: a request that fails the way a dead reused
/// connection fails goes again on a fresh one, the idle ones dropped.
pub fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) !std.http.Client.FetchResult {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        const reused = switch (options.location) {
            .url => |u| try warmTracked(client, try std.Uri.parse(u)),
            .uri => |u| try warmTracked(client, u),
        };
        if (client.fetch(options)) |r| {
            touch(client, client.io);
            return r;
        } else |e| {
            if (!reused or attempt > 0 or !isStale(e)) return e;
            _ = stale_retries.fetchAdd(1, .monotonic);
            dropIdle(client);
        }
    }
}

const testing = std.testing;

test "IPv6 and IPv4 alternate, IPv6 first, each in the order the resolver gave" {
    const a = [_]net.IpAddress{
        net.IpAddress.parse("95.101.74.217", 443) catch unreachable,
        net.IpAddress.parse("2a02:26f0:1180:71::210:6a08", 443) catch unreachable,
        net.IpAddress.parse("95.101.74.218", 443) catch unreachable,
        net.IpAddress.parse("2a02:26f0:1180:71::210:6a09", 443) catch unreachable,
        net.IpAddress.parse("95.101.74.219", 443) catch unreachable,
    };
    var out: [8]net.IpAddress = undefined;
    const o = ordered(&a, &out);
    try testing.expectEqual(@as(usize, 5), o.len);
    try testing.expect(o[0] == .ip6 and o[1] == .ip4 and o[2] == .ip6 and o[3] == .ip4 and o[4] == .ip4);
    try testing.expectEqual(@as(u8, 217), o[1].ip4.bytes[3]);
    try testing.expectEqual(@as(u8, 218), o[3].ip4.bytes[3]);
    try testing.expectEqual(@as(u8, 0x08), o[0].ip6.bytes[15]);
}

test "one family alone is kept whole" {
    const a = [_]net.IpAddress{
        net.IpAddress.parse("2001:db8::1", 443) catch unreachable,
        net.IpAddress.parse("2001:db8::2", 443) catch unreachable,
    };
    var out: [8]net.IpAddress = undefined;
    try testing.expectEqual(@as(usize, 2), ordered(&a, &out).len);
    try testing.expectEqual(@as(usize, 0), ordered(&.{}, &out).len);
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

test "a black-holed IPv6 address does not hold up the IPv4 one" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    // 100::/64 is the discard prefix: nothing routes it, so a connect either fails at once or never answers.
    const hole = net.IpAddress.parse("100::1", server.socket.address.ip4.port) catch unreachable;
    const t0 = nowMs(io);
    const got = try race(io, &.{ hole, server.socket.address }, stagger_ms, give_up_ms);
    try testing.expectEqual(server.socket.address.ip4.port, got.ip4.port);
    try testing.expect(nowMs(io) - t0 < give_up_ms / 2);
    try testing.expect(std.mem.indexOf(u8, last_note.text(), "ok in") != null);
}

test "an address list that never answers gives up within the limit" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    const hole6 = net.IpAddress.parse("100::1", 443) catch unreachable;
    const hole4 = net.IpAddress.parse("198.51.100.1", 443) catch unreachable;
    const t0 = nowMs(io);
    try testing.expect(std.meta.isError(race(io, &.{ hole6, hole4 }, 50, 1500)));
    // Bounded by the limit we gave, not by the operating system's connect wait.
    try testing.expect(nowMs(io) - t0 < 4000);
}

test "live: downloader.battle.net with a dead IPv6 and IPv4 address in front" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
    defer threaded.deinit();
    const io = threaded.io();
    var found: [32]net.IpAddress = undefined;
    const real = resolve(io, "downloader.battle.net", 443, &found) catch return error.SkipZigTest;
    var list: [34]net.IpAddress = undefined;
    list[0] = net.IpAddress.parse("100::1", 443) catch unreachable;
    list[1] = net.IpAddress.parse("198.51.100.1", 443) catch unreachable;
    @memcpy(list[2 .. 2 + real.len], real);
    const t0 = nowMs(io);
    const got = try race(io, list[0 .. 2 + real.len], stagger_ms, give_up_ms);
    try testing.expect(nowMs(io) - t0 < give_up_ms);
    var buf: [64]u8 = undefined;
    const lit = literal(got, &buf);
    try testing.expect(!std.mem.eql(u8, lit, "100::1") and !std.mem.eql(u8, lit, "198.51.100.1"));
}

/// One connection at a time: answers each request on it once with a keep-alive answer, and closes after the first
/// (a server, ingress or NAT that drops idle connections). Counts the connections and requests it saw.
const TestServer = struct {
    listener: net.Server,
    connections: std.atomic.Value(u32) = .init(0),
    requests: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),

    fn run(s: *TestServer) void {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        while (!s.stop.load(.acquire)) {
            const conn = s.listener.accept(io) catch return;
            if (s.stop.load(.acquire)) {
                conn.close(io);
                return;
            }
            _ = s.connections.fetchAdd(1, .monotonic);
            var rbuf: [2048]u8 = undefined;
            var wbuf: [512]u8 = undefined;
            var r = conn.reader(io, &rbuf);
            var w = conn.writer(io, &wbuf);
            while (true) {
                const line = r.interface.takeDelimiterInclusive('\n') catch break;
                if (!std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r\n"), "")) continue;
                _ = s.requests.fetchAdd(1, .monotonic);
                w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok") catch break;
                w.interface.flush() catch break;
                break; // the connection is closed after its first answer
            }
            conn.close(io);
        }
    }
};

fn testGet(client: *std.http.Client, url: []const u8) !void {
    var body: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&body);
    const res = try fetch(client, .{ .location = .{ .url = url }, .response_writer = &w });
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("ok", w.buffered());
}

test "a keep-alive connection the server closed while idle is retried once on a fresh one" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server: TestServer = .{ .listener = try any.listen(io, .{}) };
    const port = server.listener.socket.address.ip4.port;
    const t = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    const saved = idle_limit_ms;
    idle_limit_ms = 60_000;
    defer idle_limit_ms = saved;
    const before = stale_retries.load(.monotonic);

    try testGet(&client, url);
    // The pause: the server's close has long arrived, the pool still holds the connection.
    std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    try testGet(&client, url);

    try testing.expectEqual(before + 1, stale_retries.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), server.connections.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), server.requests.load(.monotonic));

    server.stop.store(true, .release);
    var wake = server.listener.socket.address;
    if (wake.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
    t.join();
    server.listener.deinit(io);
}

test "a connection idle past the limit is not reused, so nothing needs a retry" {
    var threaded: std.Io.Threaded = undefined;
    threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var any: net.IpAddress = .{ .ip4 = .loopback(0) };
    var server: TestServer = .{ .listener = try any.listen(io, .{}) };
    const port = server.listener.socket.address.ip4.port;
    const t = try std.Thread.spawn(.{}, TestServer.run, .{&server});
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    const saved = idle_limit_ms;
    idle_limit_ms = 50;
    defer idle_limit_ms = saved;
    const before = stale_retries.load(.monotonic);

    try testGet(&client, url);
    std.Io.sleep(io, .fromMilliseconds(300), .awake) catch {};
    try testGet(&client, url);

    try testing.expectEqual(before, stale_retries.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), server.connections.load(.monotonic));

    server.stop.store(true, .release);
    var wake = server.listener.socket.address;
    if (wake.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
    t.join();
    server.listener.deinit(io);
}
