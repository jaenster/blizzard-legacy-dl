//! blizzard-legacy-dl — fetch what Blizzard's legacy downloader stub points at.
//!
//! See src/legacy.zig for how the HTTP piece source actually works. The short version: the
//! payload is served as one numbered file per BitTorrent piece, so pieces can be fetched in any
//! order, each is verifiable on its own, and there is no session or token to establish.

const std = @import("std");
const legacy = @import("legacy");
const proxy = @import("proxy.zig");

const usage =
    \\blizzard-legacy-dl — read a Blizzard legacy downloader stub and fetch its payload
    \\
    \\  info    <stub.exe>                 what the stub carries
    \\  files   <stub.exe>                 the payload's file list
    \\  plan    <stub.exe> [n]             piece count, and the URL for piece n
    \\  fetch   <stub> [-o dir] [opts]     fetch, verify and assemble the payload
    \\  verify  <stub> [-o dir]            re-verify an assembled payload
    \\  run     <stub> [-o dir] [opts]     the whole downloader sequence, headless
    \\  proxy   [--port n]                 watch what the real downloader sends, verbatim
    \\
    \\fetch options:
    \\  --from <n>   first piece (default 0)
    \\  --to <n>     last piece, inclusive (default: the last one)
    \\  --retries <n>  per-piece retries before giving up (default 3)
    \\  --base <url> fetch pieces from a mirror instead of the (dead) Blizzard host
    \\  --sequential   fetch pieces in order; the client shuffles them, and so do we
    \\  --cookie <v>   override the CDN access token taken from the stub
    \\
    \\run options (run does everything fetch does, in the client's order):
    \\  --ini <path>          a BlizzardDownloader.ini to read config from
    \\  --server-config <url> also ask a host for /update/Downloader.ini, as the client does
    \\  --no-tracker          skip the announce
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

// Files go through `std.Io`: the POSIX calls this used before have no Windows counterpart,
// and the payload being a Windows installer makes that the one platform to support.
const File = std.Io.File;
const Dir = std.Io.Dir;

// Paths arrive both relative and absolute, and `Dir` splits those into different calls.
fn openFile(io: std.Io, path: []const u8, mode: Dir.OpenFileOptions.Mode) !File {
    return if (std.fs.path.isAbsolute(path))
        Dir.openFileAbsolute(io, path, .{ .mode = mode })
    else
        Dir.cwd().openFile(io, path, .{ .mode = mode });
}

fn createFile(io: std.Io, path: []const u8) !File {
    // `truncate = false` because the caller may be resuming into a file it preallocated on an
    // earlier run, and throwing those bytes away would restart the download.
    return if (std.fs.path.isAbsolute(path))
        Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false })
    else
        Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
}

fn zpath(gpa: std.mem.Allocator, parts: []const []const u8) ![:0]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0 and b.items.len != 0) try b.append(gpa, '/');
        try b.appendSlice(gpa, p);
    }
    return b.toOwnedSliceSentinel(gpa, 0);
}

/// Create every directory on the way to `path`, ignoring the ones already there.
fn mkdirs(io: std.Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        var root = try Dir.openDirAbsolute(io, "/", .{});
        defer root.close(io);
        try root.createDirPath(io, path[1..]);
    } else {
        try Dir.cwd().createDirPath(io, path);
    }
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try openFile(io, path, .read_only);
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
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
    var base: ?[]const u8 = null;
    var ini_path: ?[]const u8 = null;
    var server_config: ?[]const u8 = null;
    var no_tracker = false;
    var sequential = false;
    var cookie_override: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--ini") and i + 1 < argv.len) {
            i += 1;
            ini_path = argv[i];
        } else if (std.mem.eql(u8, a, "--server-config") and i + 1 < argv.len) {
            i += 1;
            server_config = argv[i];
        } else if (std.mem.eql(u8, a, "--no-tracker")) {
            no_tracker = true;
        } else if (std.mem.eql(u8, a, "--sequential")) {
            sequential = true;
        } else if (std.mem.eql(u8, a, "--cookie") and i + 1 < argv.len) {
            i += 1;
            cookie_override = argv[i];
        } else if (std.mem.eql(u8, a, "--base") and i + 1 < argv.len) {
            i += 1;
            base = argv[i];
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

    // What the real downloader puts on the wire, captured rather than guessed at. It goes
    // through WinInet, and WinInet honours the Internet Settings proxy, so standing a proxy in
    // front of it shows the request in full — including the headers WinInet adds that no amount
    // of reading the disassembly would reveal. See src/proxy.zig.
    if (std.mem.eql(u8, verb, "proxy")) {
        var port: u16 = 8888;
        var k: usize = 2;
        while (k < argv.len) : (k += 1) {
            if (std.mem.eql(u8, argv[k], "--port") and k + 1 < argv.len) {
                k += 1;
                port = try std.fmt.parseInt(u16, argv[k], 10);
            }
        }
        return proxy.run(port);
    }

    // `stubs` needs no stub of its own, so it runs before we go looking for one.
    if (std.mem.eql(u8, verb, "stubs")) {
        const dir = out_dir orelse ".";
        try mkdirs(init.io, dir);
        var got: usize = 0;
        for (products) |p| for ([_][]const u8{ "WIN", "MAC" }) |o| for (locales) |l| {
            const url = try std.fmt.allocPrint(gpa, "{s}?product={s}&locale={s}&os={s}", .{ getlegacy, p, l, o });
            const body = fetchUrl(gpa, &client, url) catch continue;
            if (body.len < 1024) continue; // an empty reply is the rate limiter, not a 404
            const ext: []const u8 = if (std.mem.eql(u8, o, "MAC")) "zip" else "exe";
            const name = try std.fmt.allocPrint(gpa, "{s}_{s}_{s}.{s}", .{ p, l, o, ext });
            const full = try zpath(gpa, &.{ dir, name });
            const f = createFile(init.io, full) catch continue;
            defer f.close(init.io);
            f.writePositionalAll(init.io, body, 0) catch continue;
            f.setLength(init.io, body.len) catch continue;
            got += 1;
            std.debug.print("  {s}  {d} bytes\n", .{ name, body.len });
        };
        std.debug.print("{d} stubs -> {s}\n", .{ got, dir });
        return;
    }

    const stub = try resolveStub(gpa, init.io, &client, argv[2], locale, os_);
    var meta = try legacy.fromStub(gpa, stub);

    // The pieces are numbered files under one base, so any host laid out the same way serves
    // them — which matters, because Blizzard's own no longer does. This replaces the whole
    // server set the torrent named, and it goes through the same expansion the client uses, so
    // `--base 'http://m[1-4]/p'` names four mirrors. See README.
    if (base) |b| {
        var mirrors: std.ArrayList(legacy.Server) = .empty;
        try legacy.expandServerUrls(gpa, std.mem.trimEnd(u8, b, "/"), &mirrors);
        meta.servers = try mirrors.toOwnedSlice(gpa);
        meta.direct_download = b;
    }

    // `run` walks the client's own start-up sequence rather than jumping straight to the
    // pieces. Each stage is printed as it happens, because most of the interesting behaviour is
    // in what the client asks for before it fetches anything.
    if (std.mem.eql(u8, verb, "run")) {
        std.debug.print("1  stub          {s} ({d} bytes)\n", .{ argv[2], stub.len });
        std.debug.print("2  metainfo      {s}, {d} pieces, {d} files, {x}\n", .{
            meta.name, meta.pieceCount(), meta.files.len, meta.infohash,
        });

        // Config, from an ini in the client's own format. directDownloadURL replaces the base;
        // cookieName and cookieData are only used when both are present.
        var cookie_name: ?[]const u8 = null;
        var cookie_data: ?[]const u8 = null;
        if (ini_path) |path| {
            const text = try readFile(gpa, init.io, path);
            var keys: usize = 0;
            var lines = std.mem.tokenizeAny(u8, text, "\r\n");
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t");
                if (line.len == 0 or line[0] == ';' or line[0] == '#' or line[0] == '[') continue;
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = std.mem.trim(u8, line[0..eq], " \t");
                const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
                keys += 1;
                if (std.mem.eql(u8, key, "directDownloadURL")) {
                    var mirrors: std.ArrayList(legacy.Server) = .empty;
                    try legacy.expandServerUrls(gpa, val, &mirrors);
                    meta.servers = try mirrors.toOwnedSlice(gpa);
                    std.debug.print("     directDownloadURL overrides the base: {s}\n", .{val});
                } else if (std.mem.eql(u8, key, "cookieName")) {
                    cookie_name = val;
                } else if (std.mem.eql(u8, key, "cookieData")) {
                    cookie_data = val;
                } else if (std.mem.eql(u8, key, "dontusetracker") or std.mem.eql(u8, key, "trackerless")) {
                    no_tracker = true;
                }
            }
            std.debug.print("3  config        {s}, {d} keys\n", .{ path, keys });
        } else {
            std.debug.print("3  config        none (no --ini)\n", .{});
        }
        if (cookie_name) |n| if (cookie_data) |d| {
            cookie = try std.fmt.allocPrint(gpa, "{s}={s}", .{ n, d });
            std.debug.print("     cookie {s} will be sent with every piece\n", .{n});
        };

        // The client asks a hardcoded host for a server-side config before it transfers
        // anything, and simply waits out the timeout when that host is gone.
        if (server_config) |host| {
            const url = try std.fmt.allocPrint(gpa, "{s}/update/Downloader.ini", .{
                std.mem.trimEnd(u8, host, "/"),
            });
            std.debug.print("4  server config {s}\n", .{url});
            if (fetchUrl(gpa, &client, url)) |body| {
                std.debug.print("     {d} bytes\n", .{body.len});
            } else |e| {
                std.debug.print("     no answer ({t}) — the client ignores this too\n", .{e});
            }
        } else {
            std.debug.print("4  server config skipped (no --server-config)\n", .{});
        }

        std.debug.print("5  servers       {d}\n", .{meta.servers.len});
        for (meta.servers) |sv| {
            if (sv.last == std.math.maxInt(u64))
                std.debug.print("     {s}  (all pieces)\n", .{sv.url})
            else
                std.debug.print("     {s}  (pieces {d}..{d})\n", .{ sv.url, sv.first, sv.last });
        }

        // The announce is worth making even against a dead tracker: a live one may hand back
        // its own set of download servers, which is the one way the URL can change at runtime.
        if (no_tracker or meta.announce.len == 0) {
            std.debug.print("6  tracker       skipped\n", .{});
        } else {
            const pid = legacy.peerId(@bitCast(@as(i64, @intCast(meta.total))));
            const url = try legacy.announceUrl(gpa, meta.announce, meta.infohash, pid, "0", .started);
            std.debug.print("6  tracker       {s}\n", .{url});
            if (fetchUrl(gpa, &client, url)) |body| {
                const r = try legacy.parseAnnounce(gpa, body);
                if (r.failure) |f| {
                    std.debug.print("     refused: {s}\n", .{f});
                } else {
                    std.debug.print("     {d} peers, {d} servers offered\n", .{ r.peers, r.servers.len });
                    if (r.servers.len != 0) {
                        // Tracker-supplied servers go in front: they are the fresher answer.
                        var all: std.ArrayList(legacy.Server) = .empty;
                        try all.appendSlice(gpa, r.servers);
                        try all.appendSlice(gpa, meta.servers);
                        meta.servers = try all.toOwnedSlice(gpa);
                        for (r.servers) |sv| std.debug.print("     + {s}\n", .{sv.url});
                    }
                }
            } else |e| {
                std.debug.print("     no answer ({t}) — this is expected, the trackers are gone\n", .{e});
            }
        }
        std.debug.print("7  pieces\n", .{});
    }

    // Without this every piece request comes back 403.
    if (meta.token) |t| cookie = t;
    if (cookie_override) |c| cookie = c;

    var b1: [32]u8 = undefined;
    if (std.mem.eql(u8, verb, "info")) {
        std.debug.print(
            \\name            : {s}
            \\locale          : {s}
            \\launch target   : {s}
            \\infohash        : {x}
            \\announce        : {s}   (dead since ~2016)
            \\direct download : {s}
            \\servers         : {d}
            \\cdn token       : {s}
            \\piece length    : {d}
            \\pieces          : {d}
            \\files           : {d}
            \\total           : {d} bytes ({s})
            \\
        , .{
            meta.name,       meta.locale, meta.launch_target, meta.infohash,
            meta.announce,   meta.direct_download, meta.servers.len,
            meta.token orelse "none — the CDN will answer 403 without one",
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
    try mkdirs(init.io, dest);

    // Preallocate every file at full length once, so a piece can be written wherever it lands
    // without caring whether the bytes around it have arrived yet.
    for (meta.files) |f| {
        const full = try zpath(gpa, &.{ dest, f.path });
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |at| try mkdirs(init.io, full[0..at]);
        const fh = try createFile(init.io, full);
        defer fh.close(init.io);
        try fh.setLength(init.io, f.length);
    }

    if (std.mem.eql(u8, verb, "verify")) {
        var bad: usize = 0;
        var buf = try gpa.alloc(u8, meta.piece_length);
        var p = from;
        while (p <= last) : (p += 1) {
            const want = meta.pieceSize(p);
            const got = try readPiece(meta, gpa, init.io, dest, p, buf[0..want]);
            meta.verify(p, got) catch {
                bad += 1;
                std.debug.print("  piece {d}: BAD\n", .{p});
            };
        }
        std.debug.print("{d} pieces checked, {d} bad\n", .{ last - from + 1, bad });
        return if (bad == 0) {} else error.Corrupt;
    }

    if (!std.mem.eql(u8, verb, "fetch") and !std.mem.eql(u8, verb, "run")) {
        std.debug.print("{s}", .{usage});
        return error.Usage;
    }

    var done: usize = 0;
    var failed: usize = 0;

    // Pieces are fetched in a random order rather than 0,1,2,... — that is what the CDN
    // expects to see, and it spreads a resumed download instead of replaying one region.
    const order = try gpa.alloc(usize, last - from + 1);
    for (order, 0..) |*o, k| o.* = from + k;
    if (!sequential) {
        // Seeded from the clock, the same way the client seeds the rand() behind its shuffle,
        // so consecutive runs do not repeat an order.
        const now = std.Io.Timestamp.now(init.io, .real);
        var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(now.nanoseconds))));
        prng.random().shuffle(usize, order);
    }

    for (order) |p| {
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
            // Each retry moves to the next server whose range covers this piece, so a mirror
            // that is down costs one attempt rather than every attempt.
            const url = try meta.pieceUrlFrom(gpa, p, s, attempt);
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
            try writePiece(meta, gpa, init.io, dest, p, body);
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

    if (std.mem.eql(u8, verb, "run")) {
        // The client announces exactly twice, started and stopped, and the second one claims
        // the download finished whether it did or not.
        if (!no_tracker and meta.announce.len != 0) {
            const pid = legacy.peerId(@bitCast(@as(i64, @intCast(meta.total))));
            const url = try legacy.announceUrl(gpa, meta.announce, meta.infohash, pid, "0", .stopped);
            std.debug.print("8  tracker       event=stopped\n", .{});
            if (fetchUrl(gpa, &client, url)) |_| {} else |_| {}
        } else {
            std.debug.print("8  tracker       skipped\n", .{});
        }
        // The client would run this itself. Printing it is as far as this goes: fetching a
        // payload is one thing, executing it unasked is another.
        std.debug.print("9  launch target {s}/{s}  (not run)\n", .{ dir_path, meta.launch_target });
    }

    if (failed != 0) return error.Incomplete;
}

/// A path on disk if there is one there, otherwise a product code to fetch from Blizzard.
fn resolveStub(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    arg: []const u8,
    locale: []const u8,
    os_: []const u8,
) ![]u8 {
    if (readFile(gpa, io, arg)) |bytes| return bytes else |_| {}

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

// The CDN access token, sent as a Cookie on every piece request.
var cookie: ?[]const u8 = null;

fn fetchUrl(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    // `Pragma: no-cache` is not the program's doing: the client opens every request with
    // INTERNET_FLAG_RELOAD, and that is what WinInet puts on the wire for it.
    const with_cookie = [_]std.http.Header{
        .{ .name = "Pragma", .value = "no-cache" },
        .{ .name = "Cookie", .value = cookie orelse "" },
    };
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = legacy.user_agent } },
        .extra_headers = if (cookie != null) &with_cookie else &.{
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
fn writePiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, io: std.Io, dest: []const u8, index: usize, data: []const u8) !void {
    var at: usize = 0;
    for (try legacy.spansForPiece(meta, gpa, index)) |s| {
        const full = try zpath(gpa, &.{ dest, meta.files[s.file].path });
        const f = try openFile(io, full, .read_write);
        defer f.close(io);
        const n: usize = @intCast(s.len);
        try f.writePositionalAll(io, data[at..][0..n], s.offset);
        at += n;
    }
}

fn readPiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, io: std.Io, dest: []const u8, index: usize, buf: []u8) ![]u8 {
    var at: usize = 0;
    for (try legacy.spansForPiece(meta, gpa, index)) |s| {
        const full = try zpath(gpa, &.{ dest, meta.files[s.file].path });
        const f = try openFile(io, full, .read_only);
        defer f.close(io);
        const n: usize = @intCast(s.len);
        at += try f.readPositionalAll(io, buf[at..][0..n], s.offset);
    }
    return buf[0..at];
}
