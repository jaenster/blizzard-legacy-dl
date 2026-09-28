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
/// Piece requests answered since the server started.
var served: std.atomic.Value(usize) = .init(0);

fn serve() void {
    while (true) {
        const c = accept(listener, null, null);
        if (c < 0) return;
        defer _ = close(c);
        _ = served.fetchAdd(1, .monotonic);

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

/// Serve `payload` as numbered pieces on a loopback port, and return the port.
fn startServer(payload: []const u8) !u16 {
    blob = payload;
    served.store(0, .monotonic);
    listener = socket(2, 1, 0);
    try std.testing.expect(listener >= 0);
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
    return port;
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

    const port = try startServer(blob);
    defer _ = close(listener);

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

// ── the installer, end to end ──────────────────────────────────────────────────────────────────

const installer = @import("installer");
const mpq = @import("libd2").formats.mpq;
const script = @import("libd2").formats.installer;

const manifest =
    \\<install>
    \\  <replace symbol="Tome1" with="Installer Tome.mpq"/>
    \\  <disc name="d" with_file="{Tome1}">
    \\    <archive input="#INPUT#" path="{Tome1}">
    \\      <if true_condition="Win32">
    \\        <then>
    \\          <target location="user">
    \\            <repack_into type="file">
    \\              <repack from="Common\d2data.mpq" to="d2data.mpq"/>
    \\              <repack from="Common\readme.txt" to="readme.txt"/>
    \\            </repack_into>
    \\            <repack_into type="mpq" container="d2data.mpq">
    \\              <repack from="PC-100\Fog.dll" to="Fog.dll"/>
    \\            </repack_into>
    \\          </target>
    \\        </then>
    \\      </if>
    \\    </archive>
    \\  </disc>
    \\</install>
;

/// A payload with an Installer Tome carrying a script, two files and an archive member, padded
/// out to several pieces. Served on a fresh port; its .torrent is written under `dir`.
const Mini = struct {
    torrent_path: []const u8,
    base: []const u8,
    total: u64,
    pieces: usize,

    fn build(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !Mini {
        const inner = try mpq.append(gpa, try mpq.empty(gpa, 16), &.{
            .{ .name = "data\\global\\excel\\armor.txt", .data = "name\tcode\n" },
        });
        const tome = try mpq.append(gpa, try mpq.empty(gpa, 16), &.{
            .{ .name = script.manifest_path, .data = manifest },
            .{ .name = "Common\\d2data.mpq", .data = inner },
            .{ .name = "Common\\readme.txt", .data = "hello" },
            .{ .name = "PC-100\\Fog.dll", .data = "MZ fog" },
        });
        const pad = try gpa.alloc(u8, 5 * piece_len + 1234);
        for (pad, 0..) |*b, i| b.* = @truncate(i *% 131);

        const parts = [_]struct { path: []const u8, data: []const u8 }{
            .{ .path = "Installer Tome.mpq", .data = tome },
            .{ .path = "pad.bin", .data = pad },
        };
        var all: std.ArrayList(u8) = .empty;
        for (parts) |f| try all.appendSlice(gpa, f.data);

        var hashes: std.ArrayList(u8) = .empty;
        var cut: usize = 0;
        while (cut < all.items.len) : (cut += piece_len) {
            var d: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(all.items[cut..@min(cut + piece_len, all.items.len)], &d, .{});
            try hashes.appendSlice(gpa, &d);
        }

        const payload_name = "Mini-Payload";
        var t: std.Io.Writer.Allocating = .init(gpa);
        const w = &t.writer;
        try w.print("d8:announce{d}:{s}", .{ "http://tracker.invalid/announce".len, "http://tracker.invalid/announce" });
        try w.print("15:direct download{d}:{s}", .{ "http://127.0.0.1/x".len, "http://127.0.0.1/x" });
        try w.writeAll("4:infod5:filesl");
        for (parts) |f| try w.print("d6:lengthi{d}e4:pathl{d}:{s}ee", .{ f.data.len, f.path.len, f.path });
        try w.print("e4:name{d}:{s}12:piece lengthi{d}e6:pieces{d}:", .{ payload_name.len, payload_name, piece_len, hashes.items.len });
        try w.writeAll(hashes.items);
        try w.writeAll("ee");

        const torrent_path = try std.fmt.allocPrint(gpa, "{s}/mini.torrent", .{dir});
        const f = try std.Io.Dir.cwd().createFile(io, torrent_path, .{});
        defer f.close(io);
        try f.writePositionalAll(io, t.written(), 0);

        const port = try startServer(all.items);
        return .{
            .torrent_path = torrent_path,
            .base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port}),
            .total = all.items.len,
            .pieces = hashes.items.len / 20,
        };
    }
};

/// Records every event, and checks as it goes that no stage's counter runs backwards.
const Recorder = struct {
    const Seen = struct { stage: installer.Stage, done: u64, total: u64, product: [8]u8, resumed: bool, piece: bool };
    gpa: std.mem.Allocator,
    events: std.ArrayList(Seen) = .empty,
    backwards: usize = 0,
    over: usize = 0,
    /// Set `cancelled` on this control after this many pieces.
    cancel_after: ?usize = null,
    control: ?*installer.Control = null,

    fn report(ctx: ?*anyopaque, ev: installer.Event) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        var product: [8]u8 = @splat(0);
        @memcpy(product[0..@min(8, ev.product.len)], ev.product[0..@min(8, ev.product.len)]);
        var i = r.events.items.len;
        while (i > 0) {
            i -= 1;
            const e = r.events.items[i];
            if (e.stage == ev.stage and std.mem.eql(u8, &e.product, &product)) {
                if (ev.done < e.done) r.backwards += 1;
                break;
            }
        }
        if (ev.total != 0 and ev.done > ev.total) r.over += 1;
        const piece = if (ev.pieces) |p| p.index != null else false;
        r.events.append(r.gpa, .{
            .stage = ev.stage,
            .done = ev.done,
            .total = ev.total,
            .product = product,
            .resumed = if (ev.pieces) |p| p.resumed else false,
            .piece = piece,
        }) catch {};
        if (r.cancel_after) |n| if (piece and ev.pieces.?.done >= n) r.control.?.cancelled.store(true, .release);
    }

    fn count(r: *const Recorder, stage: installer.Stage) usize {
        var n: usize = 0;
        for (r.events.items) |e| n += @intFromBool(e.stage == stage);
        return n;
    }

    fn pieceEvents(r: *const Recorder, resumed: bool) usize {
        var n: usize = 0;
        for (r.events.items) |e| n += @intFromBool(e.piece and e.resumed == resumed);
        return n;
    }

    fn last(r: *const Recorder, stage: installer.Stage) ?Seen {
        var i = r.events.items.len;
        while (i > 0) {
            i -= 1;
            if (r.events.items[i].stage == stage) return r.events.items[i];
        }
        return null;
    }
};

fn tmpPath(gpa: std.mem.Allocator, tmp: *const std.testing.TmpDir, leaf: []const u8) ![]const u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, leaf });
}

test "install fetches, installs, and reports every stage in order without running backwards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mini = try Mini.build(gpa, io, try tmpPath(gpa, &tmp, ""));
    defer _ = close(listener);
    var rec: Recorder = .{ .gpa = gpa };
    const game = try tmpPath(gpa, &tmp, "game");

    try installer.install(std.testing.allocator, io, .{
        .product = mini.torrent_path,
        .version = null,
        .game_dir = game,
        .cache_dir = try tmpPath(gpa, &tmp, "cache"),
        .base_url = mini.base,
        .jobs = 3,
        .progress = .{ .ctx = &rec, .report = Recorder.report },
    });

    try std.testing.expectEqual(@as(usize, 0), rec.backwards);
    try std.testing.expectEqual(@as(usize, 0), rec.over);
    try std.testing.expectEqual(mini.pieces, served.load(.monotonic));
    try std.testing.expectEqual(mini.pieces, rec.pieceEvents(false));

    // Downloading counts bytes up to the payload's size; installing ends with every step done.
    const dl = rec.last(.downloading).?;
    try std.testing.expectEqual(mini.total, dl.total);
    try std.testing.expectEqual(mini.total, dl.done);
    const inst = rec.last(.installing).?;
    try std.testing.expect(inst.total != 0);
    try std.testing.expectEqual(inst.total, inst.done);
    try std.testing.expect(rec.last(.done) != null);
    try std.testing.expectEqual(@as(usize, 0), rec.count(.patching));

    // Stages arrive in pipeline order.
    var at: u8 = 0;
    for (rec.events.items) |e| {
        try std.testing.expect(@intFromEnum(e.stage) >= at);
        at = @intFromEnum(e.stage);
    }

    // And the game directory is what the script said.
    const readme = try installer.readFile(gpa, io, try std.fmt.allocPrint(gpa, "{s}/readme.txt", .{game}));
    try std.testing.expectEqualStrings("hello", readme);
    const archive = try installer.readFile(gpa, io, try std.fmt.allocPrint(gpa, "{s}/d2data.mpq", .{game}));
    var arc = try mpq.Archive.open(gpa, archive);
    try std.testing.expectEqualStrings("MZ fog", try arc.read(gpa, "Fog.dll"));
    try std.testing.expectEqualStrings("name\tcode\n", try arc.read(gpa, "data\\global\\excel\\armor.txt"));
}

test "a paused install fetches nothing until it is resumed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mini = try Mini.build(gpa, io, try tmpPath(gpa, &tmp, ""));
    defer _ = close(listener);
    var rec: Recorder = .{ .gpa = gpa };
    var control: installer.Control = .{};
    control.paused.store(true, .release);

    const Run = struct {
        fn go(opts: installer.Options, result: *?anyerror) void {
            installer.install(std.heap.page_allocator, std.testing.io, opts) catch |e| {
                result.* = e;
            };
        }
    };
    var result: ?anyerror = null;
    const thread = try std.Thread.spawn(.{}, Run.go, .{ installer.Options{
        .product = mini.torrent_path,
        .version = null,
        .game_dir = try tmpPath(gpa, &tmp, "game"),
        .cache_dir = try tmpPath(gpa, &tmp, "cache"),
        .base_url = mini.base,
        .jobs = 2,
        .progress = .{ .ctx = &rec, .report = Recorder.report },
        .control = &control,
    }, &result });

    try io.sleep(.fromMilliseconds(400), .awake);
    try std.testing.expectEqual(@as(usize, 0), served.load(.monotonic));

    control.paused.store(false, .release);
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, null), result);
    try std.testing.expectEqual(mini.pieces, served.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), rec.backwards);
}

test "a cancelled install stops early, and the next one resumes from what is on disk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const mini = try Mini.build(gpa, io, try tmpPath(gpa, &tmp, ""));
    defer _ = close(listener);
    var control: installer.Control = .{};
    var opts: installer.Options = .{
        .product = mini.torrent_path,
        .version = null,
        .game_dir = try tmpPath(gpa, &tmp, "game"),
        .cache_dir = try tmpPath(gpa, &tmp, "cache"),
        .base_url = mini.base,
        .jobs = 1,
        .sequential = true,
        .control = &control,
    };

    // One worker, told to stop after its second piece: it takes no third.
    var first: Recorder = .{ .gpa = gpa, .cancel_after = 2, .control = &control };
    opts.progress = .{ .ctx = &first, .report = Recorder.report };
    try std.testing.expectError(error.Cancelled, installer.install(std.testing.allocator, io, opts));
    try std.testing.expectEqual(@as(usize, 2), served.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), first.count(.installing));

    // The pieces already fetched verify on disk and count at once; only the rest are fetched.
    control.cancelled.store(false, .release);
    served.store(0, .monotonic);
    var second: Recorder = .{ .gpa = gpa };
    opts.progress = .{ .ctx = &second, .report = Recorder.report };
    try installer.install(std.testing.allocator, io, opts);
    try std.testing.expectEqual(@as(usize, 2), second.pieceEvents(true));
    try std.testing.expectEqual(mini.pieces - 2, second.pieceEvents(false));
    try std.testing.expectEqual(mini.pieces - 2, served.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), second.backwards);
    try std.testing.expectEqual(mini.total, second.last(.downloading).?.done);
}
