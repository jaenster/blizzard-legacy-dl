//! End-to-end test: build a payload, serve it as numbered pieces, fetch it back and compare.
const std = @import("std");
const legacy = @import("legacy");

const piece_len = 64 * 1024;
const name = "Roundtrip-Payload";
// Not multiples of the piece length, so pieces straddle file boundaries.
const files = [_]struct { path: []const u8, len: usize }{
    .{ .path = "readme.txt", .len = 1000 },
    .{ .path = "data/one.bin", .len = 150_000 },
    .{ .path = "data/two.bin", .len = 200_003 },
};

extern "c" fn socket(d: c_int, t: c_int, p: c_int) c_int;
extern "c" fn bind(s: c_int, a: *const [16]u8, l: u32) c_int;
extern "c" fn listen(s: c_int, b: c_int) c_int;
extern "c" fn accept(s: c_int, a: ?*anyopaque, l: ?*u32) c_int;
extern "c" fn getsockname(s: c_int, a: *[16]u8, l: *u32) c_int;
extern "c" fn recv(s: c_int, b: [*]u8, l: usize, f: c_int) isize;
extern "c" fn send(s: c_int, b: [*]const u8, l: usize, f: c_int) isize;
extern "c" fn setsockopt(s: c_int, lvl: c_int, n: c_int, v: *const anyopaque, l: u32) c_int;
extern "c" fn close(s: c_int) c_int;

const is_bsd = switch (@import("builtin").os.tag) {
    .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

var blob: []const u8 = undefined;
var listener: c_int = -1;

fn serve() void {
    while (true) {
        const c = accept(listener, null, null);
        if (c < 0) return;
        defer _ = close(c);

        var buf: [4096]u8 = undefined;
        const n = recv(c, &buf, buf.len, 0);
        if (n <= 0) continue;
        const req = buf[0..@intCast(n)];

        // "GET /<index> HTTP/1.1"
        const sp = std.mem.indexOfScalar(u8, req, ' ') orelse continue;
        const rest = req[sp + 1 ..];
        var target = rest[0 .. std.mem.indexOfScalar(u8, rest, ' ') orelse continue];
        if (std.mem.indexOfScalar(u8, target, '?')) |q| target = target[0..q];
        const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse continue;
        const index = std.fmt.parseInt(usize, target[slash + 1 ..], 10) catch continue;

        const at = index * piece_len;
        if (at >= blob.len) {
            const nf = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            _ = send(c, nf.ptr, nf.len, 0);
            continue;
        }
        const body = blob[at..@min(at + piece_len, blob.len)];
        var head: [128]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch continue;
        _ = send(c, h.ptr, h.len, 0);
        var off: usize = 0;
        while (off < body.len) {
            const w = send(c, body.ptr + off, body.len - off, 0);
            if (w <= 0) break;
            off += @intCast(w);
        }
    }
}

test "a payload survives being cut into pieces, served, fetched and reassembled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var all: std.ArrayList(u8) = .empty;
    for (files) |f| {
        const body = try gpa.alloc(u8, f.len);
        for (body, 0..) |*b, i| b.* = @truncate((i * 37 + f.path.len) % 251);
        try all.appendSlice(gpa, body);
    }
    blob = all.items;

    var hashes: std.ArrayList(u8) = .empty;
    var cut: usize = 0;
    while (cut < blob.len) : (cut += piece_len) {
        var d: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(blob[cut..@min(cut + piece_len, blob.len)], &d, .{});
        try hashes.appendSlice(gpa, &d);
    }

    var t: std.Io.Writer.Allocating = .init(gpa);
    const w = &t.writer;
    try w.print("d8:announce{d}:{s}", .{ "http://tracker.invalid/announce".len, "http://tracker.invalid/announce" });
    try w.print("15:direct download{d}:{s}", .{ "http://127.0.0.1/x".len, "http://127.0.0.1/x" });
    try w.writeAll("4:infod5:filesl");
    for (files) |f| {
        try w.print("d6:lengthi{d}e4:pathl", .{f.len});
        var parts = std.mem.splitScalar(u8, f.path, '/');
        while (parts.next()) |part| try w.print("{d}:{s}", .{ part.len, part });
        try w.writeAll("ee");
    }
    try w.print("e4:name{d}:{s}12:piece lengthi{d}e6:pieces{d}:", .{ name.len, name, piece_len, hashes.items.len });
    try w.writeAll(hashes.items);
    try w.writeAll("ee");

    var meta = try legacy.fromStub(gpa, t.written());
    try std.testing.expectEqualStrings(name, meta.name);
    try std.testing.expectEqual(hashes.items.len / 20, meta.pieceCount());
    try std.testing.expectEqual(files.len, meta.files.len);

    listener = socket(2, 1, 0);
    try std.testing.expect(listener >= 0);
    defer _ = close(listener);
    var one: c_int = 1;
    _ = setsockopt(listener, if (is_bsd) 0xffff else 1, 0x0004, @ptrCast(&one), 4);
    var sa = std.mem.zeroes([16]u8);
    if (is_bsd) {
        sa[0] = 16;
        sa[1] = 2;
    } else sa[0] = 2;
    sa[4] = 127;
    sa[7] = 1;
    try std.testing.expectEqual(@as(c_int, 0), bind(listener, &sa, 16));
    try std.testing.expectEqual(@as(c_int, 0), listen(listener, 16));
    var got = std.mem.zeroes([16]u8);
    var glen: u32 = 16;
    _ = getsockname(listener, &got, &glen);
    const port = (@as(u16, got[2]) << 8) | got[3];
    (try std.Thread.spawn(.{}, serve, .{})).detach();

    var mirrors: std.ArrayList(legacy.Server) = .empty;
    try mirrors.append(gpa, .{ .url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port}) });
    meta.servers = mirrors.items;

    // Fetch every piece, check it against the torrent, and lay it back down where it belongs.
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const rebuilt = try gpa.alloc(u8, blob.len);
    @memset(rebuilt, 0);

    for (0..meta.pieceCount()) |p| {
        const url = try meta.pieceUrl(gpa, p, null);
        var body: std.Io.Writer.Allocating = .init(gpa);
        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .headers = .{ .user_agent = .{ .override = legacy.user_agent } },
            .response_writer = &body.writer,
        });
        try std.testing.expectEqual(std.http.Status.ok, res.status);

        const data = body.written();
        try meta.verify(p, data);

        var at: usize = 0;
        for (try legacy.spansForPiece(meta, gpa, p)) |s| {
            var base: usize = 0;
            for (meta.files[0..s.file]) |f| base += @intCast(f.length);
            const n: usize = @intCast(s.len);
            @memcpy(rebuilt[base + @as(usize, @intCast(s.offset)) ..][0..n], data[at..][0..n]);
            at += n;
        }
    }

    try std.testing.expectEqualSlices(u8, blob, rebuilt);
}
