//! blizzard-legacy-dl — fetch what Blizzard's legacy downloader stub points at.
//!
//! See src/legacy.zig for how the HTTP piece source actually works. The short version: the
//! payload is served as one numbered file per BitTorrent piece, so pieces can be fetched in any
//! order, each is verifiable on its own, and there is no session or token to establish.

const std = @import("std");
const legacy = @import("legacy");

const usage =
    \\blizzard-legacy-dl — read a Blizzard legacy downloader stub and fetch its payload
    \\
    \\  info    <stub.exe>                 what the stub carries
    \\  files   <stub.exe>                 the payload's file list
    \\  plan    <stub.exe> [n]             piece count, and the URL for piece n
    \\  fetch   <stub> [-o dir] [opts]     fetch, verify and assemble the payload
    \\  verify  <stub> [-o dir]            re-verify an assembled payload
    \\  sniff   [--port n]                 log what the real downloader sends, verbatim
    \\
    \\fetch options:
    \\  --from <n>   first piece (default 0)
    \\  --to <n>     last piece, inclusive (default: the last one)
    \\  --retries <n>  per-piece retries before giving up (default 3)
    \\
    \\<stub> is a downloader .exe, a Mac .app binary, a .torrent — or just a product code,
    \\which is fetched from Blizzard on the spot:
    \\
    \\  blizzard-legacy-dl info d2xp
    \\  blizzard-legacy-dl info star --locale de-DE --os MAC
    \\
    \\  products: D2DV D2XP STAR WAR3 W3XP    os: WIN (default) or MAC
    \\  locale defaults to en-US; D2 also has en-GB de-DE es-ES fr-FR it-IT ko-KR pl-PL zh-TW
    \\
    \\  stubs -o <dir>   download every product/locale/os stub there is
    \\
;

/// Blizzard's own endpoint. `www.battle.net` bounces through `eu.battle.net` to get here, so go
/// straight to it. It rate-limits: back-to-back requests come back empty, which looks exactly
/// like a missing product until you slow down.
const getlegacy = "https://downloader.battle.net/download/getLegacy";

const products = [_][]const u8{ "D2DV", "D2XP", "STAR", "WAR3", "W3XP" };
const locales = [_][]const u8{
    "en-US", "en-GB", "de-DE", "es-ES", "es-MX", "fr-FR", "it-IT",
    "ja-JP", "ko-KR", "pl-PL", "pt-BR", "ru-RU", "zh-CN", "zh-TW",
};

// std.fs is reworked under 0.16's Io interface and wants an event loop; the sibling tools in
// this stack talk to libc directly for file work, so this does too.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn pread(fd: c_int, buf: [*]u8, n: usize, off: i64) isize;
extern "c" fn pwrite(fd: c_int, buf: [*]const u8, n: usize, off: i64) isize;
extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn socket(domain: c_int, ty: c_int, proto: c_int) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, val: *const anyopaque, len: u32) c_int;
extern "c" fn bind(fd: c_int, addr: *const [16]u8, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;

// These differ per platform (O_CREAT is 0x0200 on macOS and 0o100 on Linux), so take them from
// std rather than hard-coding one OS's numbers.
const O_RDONLY: c_int = @bitCast(std.posix.O{ .ACCMODE = .RDONLY });
const O_RDWR: c_int = @bitCast(std.posix.O{ .ACCMODE = .RDWR });
const O_RDWR_CREAT: c_int = @bitCast(std.posix.O{ .ACCMODE = .RDWR, .CREAT = true });

fn zpath(gpa: std.mem.Allocator, parts: []const []const u8) ![:0]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0 and b.items.len != 0) try b.append(gpa, '/');
        try b.appendSlice(gpa, p);
    }
    return b.toOwnedSliceSentinel(gpa, 0);
}

/// Create every directory on the way to `path`, ignoring the ones already there.
fn mkdirs(gpa: std.mem.Allocator, path: []const u8) !void {
    const buf = try gpa.dupeZ(u8, path);
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        _ = mkdir(buf.ptr, 0o755);
        buf[i] = '/';
    }
    _ = mkdir(buf.ptr, 0o755);
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const zp = try gpa.dupeZ(u8, path);
    const fd = open(zp.ptr, O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var list: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

fn human(n: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    const argv_z = try init.minimal.args.toSlice(gpa);
    var argv_list: std.ArrayList([]const u8) = .empty;
    for (argv_z) |a| try argv_list.append(gpa, std.mem.sliceTo(a, 0));
    const argv = argv_list.items;
    if (argv.len < 3) {
        std.debug.print(usage, .{});
        return error.Usage;
    }
    const verb = argv[1];

    var out_dir: ?[]const u8 = null;
    var locale: []const u8 = "en-US";
    var os_: []const u8 = "WIN";
    var from: usize = 0;
    var to: ?usize = null;
    var retries: usize = 3;
    var i: usize = 3;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if ((std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--out")) and i + 1 < argv.len) {
            i += 1;
            out_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--from") and i + 1 < argv.len) {
            i += 1;
            from = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--to") and i + 1 < argv.len) {
            i += 1;
            to = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--retries") and i + 1 < argv.len) {
            i += 1;
            retries = try std.fmt.parseInt(usize, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--locale") and i + 1 < argv.len) {
            i += 1;
            locale = argv[i];
        } else if (std.mem.eql(u8, a, "--os") and i + 1 < argv.len) {
            i += 1;
            os_ = argv[i];
        }
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = init.io };
    defer client.deinit();

    // Point the CDN hostname at this machine and start the real downloader, and every request
    // it makes lands here byte for byte. That is the only way to settle what it sends that we
    // do not, when the CDN answers it and refuses us.
    //
    //   Windows, as Administrator:
    //     echo 127.0.0.1 rogue.blizzard.com.edgesuite.net >> %WINDIR%\System32\drivers\etc\hosts
    //     blizzard-legacy-dl sniff
    //   then run the downloader. Undo the hosts line afterwards.
    if (std.mem.eql(u8, verb, "sniff")) {
        var port: u16 = 80;
        var k: usize = 2;
        while (k < argv.len) : (k += 1) {
            if (std.mem.eql(u8, argv[k], "--port") and k + 1 < argv.len) {
                k += 1;
                port = try std.fmt.parseInt(u16, argv[k], 10);
            }
        }
        const fd = socket(2, 1, 0); // AF_INET, SOCK_STREAM
        if (fd < 0) return error.SocketFailed;
        var one: c_int = 1;
        _ = setsockopt(fd, 0xffff, 0x0004, @ptrCast(&one), 4); // SOL_SOCKET, SO_REUSEADDR
        var sa = std.mem.zeroes([16]u8);
        sa[0] = 16;
        sa[1] = 2; // AF_INET
        sa[2] = @intCast(port >> 8);
        sa[3] = @intCast(port & 0xff);
        if (bind(fd, &sa, 16) != 0) {
            std.debug.print("cannot bind port {d} — on Windows and Linux port 80 needs admin/root\n", .{port});
            return error.BindFailed;
        }
        if (listen(fd, 16) != 0) return error.ListenFailed;
        std.debug.print("listening on :{d}. Point rogue.blizzard.com.edgesuite.net at this host,\n" ++
            "then start the downloader. Ctrl-C when you have a request.\n\n", .{port});
        var buf: [8192]u8 = undefined;
        while (true) {
            const c = accept(fd, null, null);
            if (c < 0) continue;
            const n = read(c, &buf, buf.len);
            if (n > 0) {
                std.debug.print("─── request ───\n{s}\n", .{buf[0..@intCast(n)]});
                const reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                _ = write(c, reply.ptr, reply.len);
            }
            _ = close(c);
        }
    }

    // `stubs` needs no stub of its own, so it runs before we go looking for one.
    if (std.mem.eql(u8, verb, "stubs")) {
        const dir = out_dir orelse ".";
        try mkdirs(gpa, dir);
        var got: usize = 0;
        for (products) |p| for ([_][]const u8{ "WIN", "MAC" }) |o| for (locales) |l| {
            const url = try std.fmt.allocPrint(gpa, "{s}?product={s}&locale={s}&os={s}", .{ getlegacy, p, l, o });
            const body = fetchUrl(gpa, &client, url) catch continue;
            if (body.len < 1024) continue; // an empty reply is the rate limiter, not a 404
            const ext: []const u8 = if (std.mem.eql(u8, o, "MAC")) "zip" else "exe";
            const name = try std.fmt.allocPrint(gpa, "{s}_{s}_{s}.{s}", .{ p, l, o, ext });
            const full = try zpath(gpa, &.{ dir, name });
            const fd = open(full.ptr, O_RDWR_CREAT, @as(c_uint, 0o644));
            if (fd < 0) continue;
            _ = pwrite(fd, body.ptr, body.len, 0);
            _ = ftruncate(fd, @intCast(body.len));
            _ = close(fd);
            got += 1;
            std.debug.print("  {s}  {d} bytes\n", .{ name, body.len });
        };
        std.debug.print("{d} stubs -> {s}\n", .{ got, dir });
        return;
    }

    const stub = try resolveStub(gpa, &client, argv[2], locale, os_);
    const meta = try legacy.fromStub(gpa, stub);

    var b1: [32]u8 = undefined;
    if (std.mem.eql(u8, verb, "info")) {
        std.debug.print(
            \\name            : {s}
            \\locale          : {s}
            \\launch target   : {s}
            \\infohash        : {x}
            \\announce        : {s}   (dead since ~2016)
            \\direct download : {s}
            \\piece length    : {d}
            \\pieces          : {d}
            \\files           : {d}
            \\total           : {d} bytes ({s})
            \\
        , .{
            meta.name,       meta.locale, meta.launch_target, meta.infohash,
            meta.announce,   meta.direct_download,
            meta.piece_length, meta.pieceCount(), meta.files.len,
            meta.total,      human(meta.total, &b1),
        });
        return;
    }
    if (std.mem.eql(u8, verb, "files")) {
        for (meta.files) |f| std.debug.print("{d:>12}  {s}\n", .{ f.length, f.path });
        return;
    }
    if (std.mem.eql(u8, verb, "plan")) {
        const n = if (argv.len > 3) std.fmt.parseInt(usize, argv[3], 10) catch 0 else 0;
        const url = try meta.pieceUrl(gpa, n, null);
        std.debug.print("{d} pieces, {d} bytes each ({d} for the last)\n", .{
            meta.pieceCount(), meta.piece_length, meta.pieceSize(meta.pieceCount() - 1),
        });
        std.debug.print("piece {d}: {s}\n", .{ n, url });
        std.debug.print("  spans:\n", .{});
        for (try legacy.spansForPiece(meta, gpa, n)) |s|
            std.debug.print("    {s} +{d} for {d}\n", .{ meta.files[s.file].path, s.offset, s.len });
        return;
    }

    // The payload gets its own directory named after the torrent, so the cwd is a fine default
    // and saves typing -o . every time.
    const dir_path = out_dir orelse ".";
    const last = to orelse meta.pieceCount() - 1;

    // The payload's own top-level directory, so an assembled tree matches what the stub expects
    // to launch.
    const dest = try zpath(gpa, &.{ dir_path, meta.name });
    try mkdirs(gpa, dest);

    // Preallocate every file at full length once, so a piece can be written wherever it lands
    // without caring whether the bytes around it have arrived yet.
    for (meta.files) |f| {
        const full = try zpath(gpa, &.{ dest, f.path });
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |at| try mkdirs(gpa, full[0..at]);
        const fd = open(full.ptr, O_RDWR_CREAT, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;
        defer _ = close(fd);
        if (ftruncate(fd, @intCast(f.length)) != 0) return error.TruncateFailed;
    }

    if (std.mem.eql(u8, verb, "verify")) {
        var bad: usize = 0;
        var buf = try gpa.alloc(u8, meta.piece_length);
        var p = from;
        while (p <= last) : (p += 1) {
            const want = meta.pieceSize(p);
            const got = try readPiece(meta, gpa, dest, p, buf[0..want]);
            meta.verify(p, got) catch {
                bad += 1;
                std.debug.print("  piece {d}: BAD\n", .{p});
            };
        }
        std.debug.print("{d} pieces checked, {d} bad\n", .{ last - from + 1, bad });
        return if (bad == 0) {} else error.Corrupt;
    }

    if (!std.mem.eql(u8, verb, "fetch")) {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    }

    var done: usize = 0;
    var failed: usize = 0;
    var p = from;
    while (p <= last) : (p += 1) {
        const want = meta.pieceSize(p);
        var attempt: usize = 0;
        var last_err: []const u8 = "unknown";
        const ok = while (attempt <= retries) : (attempt += 1) {
            // The salt is the downloader's own cache-buster, used only after a bad piece.
            var salt: [12]u8 = undefined;
            const s: ?[]const u8 = if (attempt == 0) null else blk: {
                const alpha = "abcdefghijklmnopqrstuvwxyz1234567890";
                var prng = std.Random.DefaultPrng.init(@as(u64, p) *% 1000003 +% attempt);
                for (&salt) |*c| c.* = alpha[prng.random().uintLessThan(usize, alpha.len)];
                break :blk salt[0..];
            };
            const url = try meta.pieceUrl(gpa, p, s);
            const body = fetchUrl(gpa, &client, url) catch |e| {
                last_err = if (e == error.HttpStatus)
                    std.fmt.allocPrint(gpa, "HTTP {d}", .{last_status}) catch "HttpStatus"
                else
                    @errorName(e);
                continue;
            };
            if (body.len != want) {
                last_err = "short read";
                continue;
            }
            meta.verify(p, body) catch {
                last_err = "hash mismatch";
                continue;
            };
            try writePiece(meta, gpa, dest, p, body);
            break true;
        } else false;

        if (ok) {
            done += 1;
            if (done % 25 == 0 or p == last)
                std.debug.print("\r  {d}/{d} pieces", .{ done, last - from + 1 });
        } else {
            failed += 1;
            std.debug.print("\n  piece {d}: {s} after {d} tries — {s}\n", .{ p, last_err, retries + 1, try meta.pieceUrl(gpa, p, null) });
            // One failure is a blip; a wall of them is the CDN refusing this client, and
            // grinding through thousands of pieces to learn that helps nobody.
            if (failed >= 8 and done == 0) {
                std.debug.print("\n{d} pieces failed in a row, none succeeded — last error: {s}.\n" ++
                    "A 403 here means the CDN is refusing this machine rather than anything being\n" ++
                    "wrong with the request; see the README.\n", .{ failed, last_err });
                return error.AllPiecesFailed;
            }
        }
    }
    std.debug.print("\n{d} pieces written, {d} failed -> {s}/{s}\n", .{ done, failed, dir_path, meta.name });
    if (failed != 0) return error.Incomplete;
}

/// A path on disk if there is one there, otherwise a product code to fetch from Blizzard.
fn resolveStub(
    gpa: std.mem.Allocator,
    client: *std.http.Client,
    arg: []const u8,
    locale: []const u8,
    os_: []const u8,
) ![]u8 {
    if (readFile(gpa, arg)) |bytes| return bytes else |_| {}

    var code: std.ArrayList(u8) = .empty;
    for (arg) |c| try code.append(gpa, std.ascii.toUpper(c));
    const url = try std.fmt.allocPrint(gpa, "{s}?product={s}&locale={s}&os={s}", .{
        getlegacy, code.items, locale, os_,
    });
    const body = fetchUrl(gpa, client, url) catch {
        std.debug.print("no file '{s}', and fetching product {s} failed\n", .{ arg, code.items });
        return error.NoStub;
    };
    // The endpoint answers 200 with nothing when it is rate-limiting, so size is the real check.
    if (body.len < 1024) {
        std.debug.print("product {s} ({s}, {s}) returned nothing — unknown product, or you are being rate-limited\n", .{ code.items, locale, os_ });
        return error.NoStub;
    }
    return body;
}

/// The status of the last failed fetch, so a piece failure can say 403 rather than "HttpStatus".
var last_status: u16 = 0;

fn fetchUrl(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = legacy.user_agent } },
        .extra_headers = &.{
            .{ .name = "Pragma", .value = "no-cache" },
        },
        .response_writer = &body.writer,
    });
    if (res.status != .ok and res.status != .partial_content) {
        last_status = @intFromEnum(res.status);
        return error.HttpStatus;
    }
    return body.written();
}

/// A piece rarely lands in one file — it routinely straddles the end of one and the start of
/// the next — so writing one means walking its spans.
fn writePiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, dest: []const u8, index: usize, data: []const u8) !void {
    var at: usize = 0;
    for (try legacy.spansForPiece(meta, gpa, index)) |s| {
        const full = try zpath(gpa, &.{ dest, meta.files[s.file].path });
        const fd = open(full.ptr, O_RDWR);
        if (fd < 0) return error.OpenFailed;
        defer _ = close(fd);
        const n: usize = @intCast(s.len);
        if (pwrite(fd, data[at..].ptr, n, @intCast(s.offset)) != @as(isize, @intCast(n)))
            return error.WriteFailed;
        at += n;
    }
}

fn readPiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, dest: []const u8, index: usize, buf: []u8) ![]u8 {
    var at: usize = 0;
    for (try legacy.spansForPiece(meta, gpa, index)) |s| {
        const full = try zpath(gpa, &.{ dest, meta.files[s.file].path });
        const fd = open(full.ptr, O_RDONLY);
        if (fd < 0) return error.OpenFailed;
        defer _ = close(fd);
        const n: usize = @intCast(s.len);
        const got = pread(fd, buf[at..].ptr, n, @intCast(s.offset));
        if (got < 0) return error.ReadFailed;
        at += @intCast(got);
    }
    return buf[0..at];
}
