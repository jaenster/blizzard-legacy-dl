//! A logging HTTP proxy, so the real downloader can be watched instead of guessed at.
//!
//! The Blizzard downloader talks to the network through WinInet, and WinInet honours the proxy
//! named in `Internet Settings` — sending each request in absolute form, with every header the
//! program set and every header WinInet added behind its back. One listening socket therefore
//! sees the whole request exactly as it goes out, which is the only way to be sure a
//! reimplementation sends the same thing. No administrator rights, no hosts file, and the
//! download keeps working while it is watched, because requests are forwarded on.
//!
//! On the machine running the downloader, Internet Options -> Connections -> LAN settings, or
//! equivalently:
//!
//!     HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings
//!       ProxyEnable = 1   ProxyServer = <host running this>:8888
//!
//! Only the request line is altered, rewritten from absolute to origin form as any proxy must.
//! CONNECT is tunnelled untouched; its contents are TLS and there is nothing to read there.
//!
//! Sockets are used directly rather than through `std.Io`, because this runs a thread per
//! connection with a blocking read on each and the process-wide `Io` is not ours to drive from
//! those threads.
const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const is_win = native_os == .windows;
/// The BSDs, macOS among them, begin `sockaddr` with a length byte where everyone else has the
/// low half of a 16-bit address family.
const is_bsd = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

pub const Sock = if (is_win) usize else c_int;
const invalid: Sock = if (is_win) ~@as(usize, 0) else -1;

const sys = if (is_win) struct {
    pub extern "ws2_32" fn WSAStartup(v: u16, data: *[408]u8) callconv(.winapi) c_int;
    pub extern "ws2_32" fn socket(d: c_int, t: c_int, p: c_int) callconv(.winapi) Sock;
    pub extern "ws2_32" fn bind(s: Sock, a: *const [16]u8, l: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn listen(s: Sock, b: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn accept(s: Sock, a: ?*anyopaque, l: ?*c_int) callconv(.winapi) Sock;
    pub extern "ws2_32" fn connect(s: Sock, a: *const [16]u8, l: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn recv(s: Sock, b: [*]u8, l: c_int, f: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn send(s: Sock, b: [*]const u8, l: c_int, f: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn shutdown(s: Sock, how: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn closesocket(s: Sock) callconv(.winapi) c_int;
    pub extern "ws2_32" fn setsockopt(s: Sock, lvl: c_int, n: c_int, v: *const anyopaque, l: c_int) callconv(.winapi) c_int;
    pub extern "ws2_32" fn ioctlsocket(s: Sock, cmd: c_long, arg: *c_ulong) callconv(.winapi) c_int;
    pub extern "ws2_32" fn select(n: c_int, r: ?*anyopaque, w: ?*[128]u8, e: ?*anyopaque, t: *const [16]u8) callconv(.winapi) c_int;
    pub extern "ws2_32" fn getaddrinfo(n: [*:0]const u8, s: ?[*:0]const u8, h: *const AddrInfo, r: *?*AddrInfo) callconv(.winapi) c_int;
    pub extern "ws2_32" fn freeaddrinfo(r: *AddrInfo) callconv(.winapi) void;
} else struct {
    pub extern "c" fn socket(d: c_int, t: c_int, p: c_int) c_int;
    pub extern "c" fn bind(s: c_int, a: *const [16]u8, l: u32) c_int;
    pub extern "c" fn listen(s: c_int, b: c_int) c_int;
    pub extern "c" fn accept(s: c_int, a: ?*anyopaque, l: ?*u32) c_int;
    pub extern "c" fn connect(s: c_int, a: *const [16]u8, l: u32) c_int;
    pub extern "c" fn recv(s: c_int, b: [*]u8, l: usize, f: c_int) isize;
    pub extern "c" fn send(s: c_int, b: [*]const u8, l: usize, f: c_int) isize;
    pub extern "c" fn shutdown(s: c_int, how: c_int) c_int;
    pub extern "c" fn close(s: c_int) c_int;
    pub extern "c" fn setsockopt(s: c_int, lvl: c_int, n: c_int, v: *const anyopaque, l: u32) c_int;
    pub extern "c" fn fcntl(s: c_int, cmd: c_int, arg: c_int) c_int;
    pub extern "c" fn select(n: c_int, r: ?*anyopaque, w: ?*[128]u8, e: ?*anyopaque, t: *const [16]u8) c_int;
    pub extern "c" fn getaddrinfo(n: [*:0]const u8, s: ?[*:0]const u8, h: *const AddrInfo, r: *?*AddrInfo) c_int;
    pub extern "c" fn freeaddrinfo(r: *AddrInfo) void;
};

/// `struct addrinfo`. Linux puts `ai_addr` before `ai_canonname`; the BSDs and Windows put them
/// the other way round, and Windows widens `ai_addrlen` to a `size_t`.
const AddrInfo = if (native_os == .linux) extern struct {
    flags: c_int = 0,
    family: c_int = 0,
    socktype: c_int = 0,
    protocol: c_int = 0,
    addrlen: u32 = 0,
    addr: ?[*]const u8 = null,
    canonname: ?[*:0]u8 = null,
    next: ?*AddrInfo = null,
} else extern struct {
    flags: c_int = 0,
    family: c_int = 0,
    socktype: c_int = 0,
    protocol: c_int = 0,
    addrlen: if (is_win) usize else u32 = 0,
    canonname: ?[*:0]u8 = null,
    addr: ?[*]const u8 = null,
    next: ?*AddrInfo = null,
};

fn closeSock(s: Sock) void {
    if (is_win) _ = sys.closesocket(s) else _ = sys.close(s);
}

fn recvSome(s: Sock, buf: []u8) usize {
    const n = if (is_win)
        sys.recv(s, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))), 0)
    else
        sys.recv(s, buf.ptr, buf.len, 0);
    return if (n <= 0) 0 else @intCast(n);
}

fn sendAll(s: Sock, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = if (is_win)
            sys.send(s, buf.ptr + off, @intCast(@min(buf.len - off, std.math.maxInt(c_int))), 0)
        else
            sys.send(s, buf.ptr + off, buf.len - off, 0);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// An IPv4 `sockaddr_in`, laid out by hand because its first two bytes differ by platform.
fn sockaddr(ip: [4]u8, port: u16) [16]u8 {
    var sa = std.mem.zeroes([16]u8);
    if (is_bsd) {
        sa[0] = 16;
        sa[1] = 2; // AF_INET
    } else {
        sa[0] = 2;
    }
    sa[2] = @intCast(port >> 8);
    sa[3] = @truncate(port);
    @memcpy(sa[4..8], &ip);
    return sa;
}

pub fn run(bind_addr: [4]u8, port: u16) !void {
    if (is_win) {
        var wsa: [408]u8 = undefined;
        _ = sys.WSAStartup(0x0202, &wsa);
    }

    const srv = sys.socket(2, 1, 0); // AF_INET, SOCK_STREAM
    if (srv == invalid) return error.SocketFailed;
    var one: c_int = 1;
    _ = sys.setsockopt(srv, if (is_bsd) 0xffff else 1, 0x0004, @ptrCast(&one), 4); // SO_REUSEADDR

    const sa = sockaddr(bind_addr, port);
    if (sys.bind(srv, &sa, 16) != 0) {
        std.debug.print("cannot bind :{d} — something else is already on it\n", .{port});
        return error.BindFailed;
    }
    if (sys.listen(srv, 64) != 0) return error.ListenFailed;

    std.debug.print(
        \\proxy listening on {d}.{d}.{d}.{d}:{d}
        \\
        \\point the downloader's machine at it — Internet Options -> Connections ->
        \\LAN settings -> proxy — then start the downloader. Every request it makes
        \\is printed here, verbatim, and forwarded on.
        \\
        \\
    , .{ bind_addr[0], bind_addr[1], bind_addr[2], bind_addr[3], port });

    while (true) {
        const c = sys.accept(srv, null, null);
        if (c == invalid) continue;
        const t = std.Thread.spawn(.{}, serve, .{c}) catch {
            closeSock(c);
            continue;
        };
        t.detach();
    }
}

fn serve(client: Sock) void {
    defer closeSock(client);

    var head: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    const end = while (len < head.len) {
        const n = recvSome(client, head[len..]);
        if (n == 0) return;
        len += n;
        if (std.mem.indexOf(u8, head[0..len], "\r\n\r\n")) |at| break at + 4;
    } else return;

    std.debug.print("\n─── request ───\n{s}", .{head[0..end]});

    const line_end = std.mem.indexOf(u8, head[0..end], "\r\n") orelse return;
    var parts = std.mem.tokenizeScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return;
    const target = parts.next() orelse return;
    const version = parts.next() orelse "HTTP/1.1";

    if (std.mem.eql(u8, method, "CONNECT")) {
        const host, const port = splitHostPort(target, 443);
        const up = dial(host, port) catch |e| {
            std.debug.print("   !! {s}:{d}: {t}\n", .{ host, port, e });
            return;
        };
        defer closeSock(up);
        if (!sendAll(client, "HTTP/1.1 200 Connection Established\r\n\r\n")) return;
        std.debug.print("   tunnelled to {s}:{d} — contents are TLS\n", .{ host, port });
        relay(client, up, false);
        return;
    }

    if (!std.mem.startsWith(u8, target, "http://")) {
        std.debug.print("   !! not an absolute-form request — is the client really using this as a proxy?\n", .{});
        return;
    }
    const rest = target["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host, const port = splitHostPort(rest[0..slash], 80);
    const path = if (slash < rest.len) rest[slash..] else "/";

    const up = dial(host, port) catch |e| {
        std.debug.print("   !! {s}:{d}: {t}\n", .{ host, port, e });
        return;
    };
    defer closeSock(up);

    // Absolute form is for us; the origin gets the path on its own, as any proxy would send it.
    var line: [8 * 1024]u8 = undefined;
    const rewritten = std.fmt.bufPrint(&line, "{s} {s} {s}\r\n", .{ method, path, version }) catch return;
    if (!sendAll(up, rewritten)) return;
    if (!sendAll(up, head[line_end + 2 .. len])) return; // headers, and any body already read

    relay(client, up, true);
}

/// Copy between the two until either goes quiet. The upstream direction runs here so the first
/// line of the reply can be reported; the client direction runs on its own thread.
fn relay(client: Sock, up: Sock, report: bool) void {
    const t = std.Thread.spawn(.{}, pump, .{ client, up }) catch return;
    defer t.join();

    var buf: [64 * 1024]u8 = undefined;
    var first = report;
    while (true) {
        const n = recvSome(up, &buf);
        if (n == 0) break;
        if (first) {
            first = false;
            const nl = std.mem.indexOfScalar(u8, buf[0..n], '\r') orelse n;
            std.debug.print("   -> {s}\n", .{buf[0..nl]});
        }
        if (!sendAll(client, buf[0..n])) break;
    }
    _ = sys.shutdown(client, if (is_win) 2 else 2); // SHUT_RDWR
    _ = sys.shutdown(up, 2);
}

fn pump(client: Sock, up: Sock) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = recvSome(client, &buf);
        if (n == 0) break;
        if (!sendAll(up, buf[0..n])) break;
    }
    _ = sys.shutdown(up, if (is_win) 1 else 1); // SHUT_WR
}

// Resolve through the platform resolver, not Zig's — that one reads /etc/resolv.conf,
// which on macOS is a placeholder, so a VPN resolver there breaks some lookups.
fn dial(host: []const u8, port: u16) !Sock {
    var name: [256]u8 = undefined;
    if (host.len >= name.len) return error.NameTooLong;
    @memcpy(name[0..host.len], host);
    name[host.len] = 0;

    const hints: AddrInfo = .{ .family = 2, .socktype = 1 };
    var list: ?*AddrInfo = null;
    if (sys.getaddrinfo(@ptrCast(&name), null, &hints, &list) != 0) return error.UnknownHostName;
    defer if (list) |l| sys.freeaddrinfo(l);

    var it = list;
    while (it) |ai| : (it = ai.next) {
        const addr = ai.addr orelse continue;
        // `sockaddr_in` holds the address at byte 4 on every platform here: the four bytes
        // before it are the family (and, on the BSDs, a length byte) and the port.
        const sa = sockaddr(addr[4..8].*, port);
        const s = sys.socket(2, 1, 0);
        if (s == invalid) continue;
        if (connectTimeout(s, &sa, connect_seconds)) return s;
        closeSock(s);
    }
    return error.ConnectionRefused;
}

// How long to wait for an upstream before giving up. The OS default is over a minute,
// and the client asks a long-dead address before it transfers anything.
const connect_seconds: i64 = 8;

// Connect with a deadline: go non-blocking, connect, wait for writability, restore.
fn connectTimeout(s: Sock, sa: *const [16]u8, seconds: i64) bool {
    setNonBlocking(s, true);
    defer setNonBlocking(s, false);

    if (sys.connect(s, sa, 16) == 0) return true;

    // An fd_set is a bitmap of descriptors; on Windows it is a count followed by handles. Both
    // fit in this buffer for the single descriptor being waited on.
    var set = std.mem.zeroes([128]u8);
    if (is_win) {
        std.mem.writeInt(u32, set[0..4], 1, .little);
        std.mem.writeInt(u64, set[8..16], @intCast(s), .little);
    } else {
        const fd: usize = @intCast(s);
        if (fd >= 1024) return false;
        set[fd / 8] |= @as(u8, 1) << @intCast(fd % 8);
    }

    var tv = std.mem.zeroes([16]u8);
    std.mem.writeInt(i64, tv[0..8], seconds, .little);
    const n: c_int = if (is_win) 0 else @as(c_int, @intCast(s)) + 1;
    if (sys.select(n, null, &set, null, &tv) <= 0) return false;

    // Writable can also mean "refused"; a zero-length send settles which.
    return sendAll(s, "");
}

fn setNonBlocking(s: Sock, on: bool) void {
    if (is_win) {
        var v: c_ulong = if (on) 1 else 0;
        _ = sys.ioctlsocket(s, @bitCast(@as(u32, 0x8004667E)), &v); // FIONBIO
    } else {
        const flags = sys.fcntl(s, 3, 0); // F_GETFL
        if (flags < 0) return;
        const nonblock: c_int = 0x0004; // O_NONBLOCK, same on macOS and Linux
        _ = sys.fcntl(s, 4, if (on) flags | nonblock else flags & ~nonblock); // F_SETFL
    }
}

fn splitHostPort(s: []const u8, default: u16) struct { []const u8, u16 } {
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
        const p = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return .{ s, default };
        return .{ s[0..c], p };
    }
    return .{ s, default };
}
