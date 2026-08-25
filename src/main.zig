//! blizzard-legacy-dl — fetch what Blizzard's legacy downloader stub points at.
//!
//! See src/legacy.zig for how the HTTP piece source actually works. The short version: the
//! payload is served as one numbered file per BitTorrent piece, so pieces can be fetched in any
//! order, each is verifiable on its own, and there is no session or token to establish.

const std = @import("std");
const legacy = @import("legacy");
const proxy = @import("proxy.zig");
const mpq = @import("libd2").formats.mpq;
const script = @import("libd2").formats.installer;
const ptc = @import("libd2").formats.ptc;

const usage =
    \\blizzard-legacy-dl — read a Blizzard legacy downloader stub and fetch its payload
    \\
    \\  info    <stub.exe>                 what the stub carries
    \\  files   <stub.exe>                 the payload's file list
    \\  plan    <stub.exe> [n]             piece count, and the URL for piece n
    \\  fetch   <stub> [-o dir] [opts]     fetch, verify and assemble the payload
    \\  verify  <stub> [-o dir]            re-verify an assembled payload
    \\  install <stub> [-o dir] [opts]     fetch, then build the game directory from it
    \\  run     <stub> [-o dir] [opts]     the whole downloader sequence, headless
    \\  proxy   [--port n] [--bind ip]     watch what the real downloader sends, verbatim
    \\
    \\fetch options:
    \\  --from <n>   first piece (default 0)
    \\  --to <n>     last piece, inclusive (default: the last one)
    \\  --retries <n>  per-piece retries before giving up (default 3)
    \\  --base <url> fetch pieces from a mirror instead of the (dead) Blizzard host
    \\  --jobs <n>     pieces to fetch at once (default 4)
    \\  --sequential   fetch pieces in order; the client shuffles them, and so do we
    \\  --cookie <v>   override the CDN access token taken from the stub
    \\  --game <dir>   where install puts the game (default: alongside, named "<payload>-game")
    \\  --no-base      install an expansion on its own, without its base game first
    \\  --version <v>  install an older version, e.g. 1.09b (or give it as the 3rd argument)
    \\  --patch-source where patch archives come from
    \\  --platform <p> win32 (default) or macos, for install
    \\  --lang <name>  install this language branch (default English)
    \\
    \\run options (run does everything fetch does, in the client's order):
    \\  --ini <path>          a BlizzardDownloader.ini to read config from
    \\  --server-config <url> also ask a host for /update/Downloader.ini, as the client does
    \\  --no-tracker          skip the announce
    \\
    \\<stub> is a downloader .exe, a Mac .zip, a .torrent — or just a product code,
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

fn writeWhole(io: std.Io, path: []const u8, data: []const u8) !void {
    const f = try createFile(io, path);
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
    try f.setLength(io, data.len);
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
    if (argv.len < 2) {
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
    var jobs: usize = 4;
    var cookie_override: ?[]const u8 = null;
    var game_dir: ?[]const u8 = null;
    var no_base = false;
    var want_version: ?[]const u8 = null;
    var patch_source: []const u8 = "https://files.typeguru.nl/diablo/patches/pc";
    var platform: []const u8 = "win32";
    var language: []const u8 = "English";
    var i: usize = 3;
    if (argv.len > 3 and argv[3].len != 0 and (std.ascii.isDigit(argv[3][0]))) {
        want_version = argv[3];
        i = 4;
    }
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
        } else if (std.mem.eql(u8, a, "--jobs") and i + 1 < argv.len) {
            i += 1;
            jobs = @max(1, try std.fmt.parseInt(usize, argv[i], 10));
        } else if (std.mem.eql(u8, a, "--sequential")) {
            sequential = true;
        } else if (std.mem.eql(u8, a, "--version") and i + 1 < argv.len) {
            i += 1;
            want_version = argv[i];
        } else if (std.mem.eql(u8, a, "--patch-source") and i + 1 < argv.len) {
            i += 1;
            patch_source = argv[i];
        } else if (std.mem.eql(u8, a, "--no-base")) {
            no_base = true;
        } else if (std.mem.eql(u8, a, "--game") and i + 1 < argv.len) {
            i += 1;
            game_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--platform") and i + 1 < argv.len) {
            i += 1;
            platform = argv[i];
        } else if (std.mem.eql(u8, a, "--lang") and i + 1 < argv.len) {
            i += 1;
            language = argv[i];
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
        // Loopback by default: binding every interface turns this into an open relay for
        // whoever else is on the network. Another machine needs --bind 0.0.0.0.
        var bind_addr: [4]u8 = .{ 127, 0, 0, 1 };
        var k: usize = 2;
        while (k < argv.len) : (k += 1) {
            if (std.mem.eql(u8, argv[k], "--port") and k + 1 < argv.len) {
                k += 1;
                port = try std.fmt.parseInt(u16, argv[k], 10);
            } else if (std.mem.eql(u8, argv[k], "--bind") and k + 1 < argv.len) {
                k += 1;
                var it = std.mem.splitScalar(u8, argv[k], '.');
                for (&bind_addr) |*o| o.* = std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0;
            }
        }
        return proxy.run(bind_addr, port);
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

    if (argv.len < 3) {
        std.debug.print(usage, .{});
        return error.Usage;
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
            meta.name,              meta.locale,          meta.launch_target, meta.infohash,
            meta.announce,          meta.direct_download, meta.servers.len,
            meta.token orelse "none — the CDN will answer 403 without one",
            meta.piece_length,      meta.pieceCount(),    meta.files.len,     meta.total,
            human(meta.total, &b1),
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

    // An expansion installs over its base game, so asking to install one means installing both,
    // base first. Only `install` does this: fetching an expansion on its own is a fine thing to
    // want, and `run` walks one payload by definition.
    var code_buf: [8]u8 = undefined;
    const code = if (argv[2].len <= code_buf.len) blk: {
        for (argv[2], 0..) |c, k| code_buf[k] = std.ascii.toUpper(c);
        break :blk code_buf[0..argv[2].len];
    } else argv[2];
    const both = std.mem.eql(u8, verb, "install") and !no_base;
    const code_last = argv[2];
    const targets: []const []const u8 =
        if (both and std.mem.eql(u8, code, "D2XP")) &.{ "D2DV", "D2XP" } else if (both and std.mem.eql(u8, code, "W3XP")) &.{ "WAR3", "W3XP" } else &.{argv[2]};

    // Both halves land in one game directory, named for what was actually asked for.
    const game_root = game_dir orelse try std.fmt.allocPrint(gpa, "{s}/{s}-game", .{ dir_path, meta.name });

    for (targets) |target| {
        // Resolve every target, not just the ones that differ by name: the base pass overwrites
        // `meta`, so the expansion pass cannot reuse what was resolved before the loop.
        if (targets.len > 1) {
            std.debug.print("\n=== {s} ===\n", .{target});
            const base_stub = try resolveStub(gpa, init.io, &client, target, locale, os_);
            meta = try legacy.fromStub(gpa, base_stub);
            if (meta.token) |t| cookie = t;
            if (cookie_override) |c| cookie = c;
        }
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
                const got = readPiece(meta, gpa, init.io, dest, p, buf[0..want]) catch "";
                meta.verify(p, got) catch {
                    bad += 1;
                    std.debug.print("  piece {d}: BAD\n", .{p});
                };
            }
            std.debug.print("{d} pieces checked, {d} bad\n", .{ last - from + 1, bad });
            return if (bad == 0) {} else error.Corrupt;
        }

        if (!std.mem.eql(u8, verb, "fetch") and !std.mem.eql(u8, verb, "run") and
            !std.mem.eql(u8, verb, "install"))
        {
            std.debug.print("{s}", .{usage});
            return error.Usage;
        }

        var done: usize = 0;
        var failed: usize = 0;
        var resumed: usize = 0;

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

        // Each piece allocates a body, a URL and a span list. Without a reset they accumulate to
        // the size of the payload, which for these is well over a gigabyte.
        var scratch_state = std.heap.ArenaAllocator.init(gpa);
        defer scratch_state.deinit();

        // The map only makes sense on a terminal; piped or in CI it would be a wall of escapes.
        const tty = (std.Io.File.stderr().isTty(init.io) catch false);
        var grid: ?Grid = if (tty) try Grid.init(gpa, init.io, last - from + 1) else null;

        // Several pieces at once. The real client does the same, governed by its maxpending and
        // maxsimultaneous settings; neither it nor this caps the download rate itself.
        var shared: Fetch = .{
            .meta = meta,
            .order = order,
            .from = from,
            .last = last,
            .dest = dest,
            .retries = retries,
            .grid = if (grid) |*g| g else null,
        };

        {
            const workers = try gpa.alloc(std.Thread, jobs);
            defer gpa.free(workers);
            var spawned: usize = 0;
            for (workers) |*t| {
                t.* = std.Thread.spawn(.{}, Fetch.work, .{&shared}) catch break;
                spawned += 1;
            }
            // If no thread could start, do the work here rather than silently finishing early.
            if (spawned == 0) Fetch.work(&shared) else for (workers[0..spawned]) |t| t.join();
        }

        done = shared.done;
        failed = shared.failed;
        resumed = shared.resumed;
        if (shared.gave_up) {
            if (grid) |*g| g.draw(done, failed, true);
            std.debug.print("\n{d} pieces failed and none succeeded.\n" ++
                "A 403 here usually means the stub's access token has expired; fetch a fresh\n" ++
                "stub by asking for the product code, or pass --cookie. See the README.\n", .{failed});
            return error.AllPiecesFailed;
        }

        if (grid) |*g| g.draw(done, failed, true);
        if (resumed != 0)
            std.debug.print("\n{d} pieces written, {d} already had, {d} failed -> {s}/{s}\n", .{ done - resumed, resumed, failed, dir_path, meta.name })
        else
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

        if (std.mem.eql(u8, verb, "install")) try install(gpa, init.io, dest, game_root, platform, language, if (std.mem.eql(u8, target, code_last)) want_version else null, patch_source, &client);
    } // end of the per-product loop
}

/// Take a game directory back to an older version, the way Blizzard's patch installer does.
///
/// The payload carries the original build of each product — 1.00 for the base game, 1.07 for the
/// expansion — under `PC-100`/`PC-100x`. Patches are cumulative ("upgrades from version 1.00 or
/// later", as the 1.09 script puts it), so one archive gets from that base to any later version.
///
/// Two tables drive it. One maps members to files on disk; the other, `patch.lst`, maps members
/// into `patch_d2.mpq`, which the script deletes and rebuilds outright rather than adding to.
fn patchTo(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    set: *const mpq.Set,
    game: []const u8,
    version: []const u8,
    expansion: bool,
    source: []const u8,
) !void {
    // Version strings are written 1.09b but the archives are named 109b.
    var tidy: std.ArrayList(u8) = .empty;
    for (version) |c| if (c != '.') try tidy.append(gpa, c);
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}Patch_{s}.exe", .{
        source, if (expansion) "LOD" else "D2", tidy.items,
    });
    std.debug.print("\npatching to {s}\n  {s}\n", .{ version, url });

    const exe = fetchUrl(gpa, client, url) catch |e| {
        std.debug.print("  no patch archive for {s} ({t})\n", .{ version, e });
        return error.NoSuchVersion;
    };
    var patch = try mpq.Archive.open(gpa, exe);
    defer patch.deinit(gpa);

    // The base to patch, straight out of the payload.
    const prefix = if (expansion) "PC-100x\\" else "PC-100\\";
    var base: std.StringHashMapUnmanaged([]const u8) = .empty;

    // The disk map has no fixed name, so it is found by shape: the only member that is text and
    // pairs members with $(InstallPath) destinations.
    var disk_map: ?[]const u8 = null;
    for (0..patch.blocks.len) |i| {
        const idx: u32 = @intCast(i);
        const key = patch.recoverKey(gpa, idx) catch null;
        const data = patch.readBlock(gpa, idx, key) catch continue;
        if (data.len > 8192 or data.len < 16) continue;
        if (std.mem.indexOf(u8, data, ";$(InstallPath)") != null) {
            disk_map = data;
            break;
        }
    }

    var wrote: usize = 0;
    if (disk_map) |text| {
        for (try ptc.parseMap(gpa, text)) |m| {
            const rec_bytes = patch.read(gpa, m.member) catch continue;
            const rec = ptc.Record.parse(rec_bytes) catch continue;
            const name = m.basename();

            // The source is the original build for this product, not what is on disk.
            const src = base.get(name) orelse blk: {
                const member = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
                const b = set.read(gpa, member) catch &[_]u8{};
                try base.put(gpa, name, b);
                break :blk b;
            };
            const out = ptc.apply(gpa, rec, src) catch |e| {
                std.debug.print("  refused {s}: {t}\n", .{ name, e });
                continue;
            };
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, name });
            try writeWhole(io, full, out);
            wrote += 1;
        }
    }

    // patch_d2.mpq is rebuilt from nothing, exactly as the script asks.
    var rebuilt: usize = 0;
    if (patch.read(gpa, "patch.lst")) |lst| {
        var members: std.ArrayList(mpq.NewFile) = .empty;
        for (try ptc.parseMap(gpa, lst)) |m| {
            // Here the pair is the other way round: archive path first, member second.
            const data = patch.read(gpa, m.destination) catch continue;
            const rec = ptc.Record.parse(data) catch continue;
            const body = ptc.apply(gpa, rec, &[_]u8{}) catch continue;
            try members.append(gpa, .{ .name = m.member, .data = body });
        }
        if (members.items.len != 0) {
            var slots: u32 = 16;
            while (slots < members.items.len * 2) slots *= 2;
            const empty = try mpq.empty(gpa, slots);
            const built = try mpq.append(gpa, empty, members.items);
            const full = try std.fmt.allocPrint(gpa, "{s}/patch_d2.mpq", .{game});
            try writeWhole(io, full, built);
            rebuilt = members.items.len;
        }
    } else |_| {}

    std.debug.print("  {d} files patched, patch_d2.mpq rebuilt with {d} members\n", .{ wrote, rebuilt });
}

/// Build the game directory from a payload that has just been fetched.
///
/// The payload's archives hold both the files and the script saying where they go. Everything the
/// script asks for that has meaning off Windows is done; the registry keys, shortcuts and DirectX
/// bundle it also asks for are counted and reported instead.
fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
    game: []const u8,
    platform: []const u8,
    language: []const u8,
    version: ?[]const u8,
    patch_source: []const u8,
    client: *std.http.Client,
) !void {
    // The script names its own archives Tome1..Tome6; a payload has one of them, or a few.
    var set: mpq.Set = .{};
    defer set.deinit(gpa);
    var found: usize = 0;
    for (0..6) |n| {
        const name = if (n == 0)
            try std.fmt.allocPrint(gpa, "{s}/Installer Tome.mpq", .{payload})
        else
            try std.fmt.allocPrint(gpa, "{s}/Installer Tome {d}.mpq", .{ payload, n + 1 });
        const bytes = readFile(gpa, io, name) catch continue;
        set.add(gpa, bytes) catch continue;
        found += 1;
    }
    if (found == 0) {
        std.debug.print("no Installer Tome in {s}\n", .{payload});
        return error.NoTome;
    }

    const manifest = set.read(gpa, script.manifest_path) catch {
        std.debug.print("the payload carries no install script\n", .{});
        return error.NoManifest;
    };
    // An expansion installs over the base game, and deletes from where it already sits.
    const original = try std.fmt.allocPrint(gpa, "{s}/", .{game});
    const plan = try script.parse(gpa, manifest, .{
        .platform = if (std.mem.eql(u8, platform, "macos")) .macos else .win32,
        .language = language,
        .symbols = &.{.{ .name = "OriginalInstallPath", .value = original }},
    });

    std.debug.print("\ninstalling {d} operations from {d} archive(s) -> {s}\n", .{ plan.ops.len, found, game });
    try mkdirs(io, game);

    var wrote: usize = 0;
    var added: usize = 0;
    var elsewhere: usize = 0;
    var pending: std.ArrayList(@TypeOf(@as(script.Op, undefined).add_to_archive)) = .empty;

    for (plan.ops) |op| switch (op) {
        .extract => |f| {
            const from = f.from orelse continue;
            const data = set.read(gpa, from) catch continue;
            defer gpa.free(data);
            const rel = try gpa.dupe(u8, f.to);
            defer gpa.free(rel);
            for (rel) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, rel });
            defer gpa.free(full);
            if (std.mem.lastIndexOfScalar(u8, full, '/')) |cut| try mkdirs(io, full[0..cut]);
            try writeWhole(io, full, data);
            wrote += 1;
        },
        .add_to_archive => |a| try pending.append(gpa, a),
        .delete => |path| {
            const rel = try gpa.dupe(u8, path);
            defer gpa.free(rel);
            for (rel) |*c| if (c.* == '\\') {
                c.* = '/';
            };
            const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, rel });
            defer gpa.free(full);
            Dir.cwd().deleteFile(io, full) catch {};
            std.debug.print("  replacing {s}\n", .{rel});
        },
        else => elsewhere += 1,
    };

    // One rewrite per archive, carrying every member bound for it.
    var done_containers: std.StringHashMapUnmanaged(void) = .empty;
    for (pending.items) |a| {
        if (done_containers.contains(a.container)) continue;
        try done_containers.put(gpa, a.container, {});
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, a.container });
        defer gpa.free(path);
        const before = readFile(gpa, io, path) catch continue;
        defer gpa.free(before);

        var add: std.ArrayList(mpq.NewFile) = .empty;
        defer add.deinit(gpa);
        for (pending.items) |b| {
            if (!std.mem.eql(u8, b.container, a.container)) continue;
            const from = b.file.from orelse continue;
            const data = set.read(gpa, from) catch continue;
            try add.append(gpa, .{ .name = b.file.to, .data = data });
        }
        const grown = mpq.append(gpa, before, add.items) catch continue;
        defer gpa.free(grown);
        try writeWhole(io, path, grown);
        added += add.items.len;
    }

    std.debug.print("{d} files, {d} members added to installed archives, {d} steps only Windows can do\n", .{ wrote, added, elsewhere });

    if (version) |v| try patchTo(gpa, io, client, &set, game, v, found > 0 and set.has("PC-100x\\Game.exe"), patch_source);
    std.debug.print("the game is in {s}\n", .{game});
}

/// A piece map, the way a torrent client draws one: a grid of cells, each standing for a run of
/// pieces, filling in as they arrive. Because pieces are fetched in a random order the map fills
/// scattered rather than left to right, which is what the real downloader looked like.
const Grid = struct {
    const shades = [_][]const u8{ " ", "\u{2591}", "\u{2592}", "\u{2593}", "\u{2588}" };

    cols: usize,
    rows: usize,
    per_cell: usize,
    have: []u32,
    cap: []u32,
    bad: []u32,
    total: usize,
    drawn: bool = false,
    last_draw: i128 = 0,
    drawing: std.atomic.Value(bool) = .init(false),
    io: std.Io,

    fn init(gpa: std.mem.Allocator, io: std.Io, pieces: usize) !Grid {
        const cols: usize = 64;
        const rows: usize = @min(8, (pieces + cols - 1) / cols);
        const cells = @max(1, cols * rows);
        const per = (pieces + cells - 1) / cells;
        var g: Grid = .{
            .cols = cols,
            .rows = rows,
            .per_cell = @max(1, per),
            .have = try gpa.alloc(u32, cells),
            .cap = try gpa.alloc(u32, cells),
            .bad = try gpa.alloc(u32, cells),
            .total = pieces,
            .io = io,
        };
        @memset(g.have, 0);
        @memset(g.bad, 0);
        @memset(g.cap, 0);
        for (0..pieces) |i| g.cap[@min(cells - 1, i / g.per_cell)] += 1;
        return g;
    }

    fn cell(g: *Grid, piece: usize) usize {
        return @min(g.have.len - 1, piece / g.per_cell);
    }

    fn mark(g: *Grid, piece: usize, ok: bool) void {
        const c = g.cell(piece);
        _ = @atomicRmw(u32, if (ok) &g.have[c] else &g.bad[c], .Add, 1, .monotonic);
    }

    /// Redraw in place, at most a dozen times a second — often enough to look alive, rarely
    /// enough not to drown a slow terminal.
    fn draw(g: *Grid, done: usize, failed: usize, force: bool) void {
        // Whoever gets here first draws; the others carry on downloading rather than queue up
        // behind a terminal. At a dozen frames a second nobody misses the skipped ones.
        if (g.drawing.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer g.drawing.store(false, .release);

        const now = std.Io.Timestamp.now(g.io, .real).nanoseconds;
        if (!force and now - g.last_draw < 80 * std.time.ns_per_ms) return;
        g.last_draw = now;

        var out: [8 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        if (g.drawn) w.print("\x1b[{d}A", .{g.rows + 2}) catch return;
        g.drawn = true;

        for (0..g.rows) |r| {
            w.writeAll("  ") catch return;
            for (0..g.cols) |c| {
                const i = r * g.cols + c;
                if (i >= g.have.len) break;
                const capacity = g.cap[i];
                if (capacity == 0) {
                    w.writeAll(" ") catch return;
                    continue;
                }
                if (g.bad[i] != 0 and g.have[i] < capacity) {
                    w.writeAll("\x1b[31m\u{2593}\x1b[0m") catch return;
                    continue;
                }
                const level = (g.have[i] * (shades.len - 1) + capacity - 1) / capacity;
                if (level >= shades.len - 1) {
                    w.print("\x1b[32m{s}\x1b[0m", .{shades[shades.len - 1]}) catch return;
                } else {
                    w.writeAll(shades[level]) catch return;
                }
            }
            w.writeAll("\x1b[K\n") catch return;
        }
        const pct = if (g.total == 0) 100 else done * 100 / g.total;
        w.print("\n  {d}/{d} pieces  {d}%", .{ done, g.total, pct }) catch return;
        if (failed != 0) w.print("  \x1b[31m{d} failed\x1b[0m", .{failed}) catch return;
        w.writeAll("\x1b[K\n") catch return;
        std.debug.print("{s}", .{w.buffered()});
    }
};

/// The shared state a set of fetch workers pulls from. Counters are atomic and the piece cursor
/// is a fetch-and-add, so a worker only ever needs the next index and never waits on the others.
const Fetch = struct {
    meta: legacy.Metainfo,
    order: []const usize,
    from: usize,
    last: usize,
    dest: []const u8,
    retries: usize,
    grid: ?*Grid,

    cursor: usize = 0,
    done: usize = 0,
    failed: usize = 0,
    resumed: usize = 0,
    gave_up: bool = false,

    fn take(f: *Fetch) ?usize {
        const i = @atomicRmw(usize, &f.cursor, .Add, 1, .monotonic);
        if (i >= f.order.len) return null;
        return f.order[i];
    }

    fn work(f: *Fetch) void {
        // Everything here is this thread's own: its allocator, its Io and its HTTP client.
        // An arena is not shared safely, and neither is the process-wide Io.
        // The client and the Io outlive every piece, so they must NOT come from the arena that
        // gets reset per piece - resetting it would pull their memory out from under them.
        const stable = std.heap.page_allocator;
        var threaded: std.Io.Threaded = .init(stable, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var client: std.http.Client = .{ .allocator = stable, .io = io };
        defer client.deinit();

        var scratch_state = std.heap.ArenaAllocator.init(stable);
        defer scratch_state.deinit();

        while (f.take()) |p| {
            if (@atomicLoad(bool, &f.gave_up, .monotonic)) return;
            _ = scratch_state.reset(.retain_capacity);
            const scratch = scratch_state.allocator();
            const want = f.meta.pieceSize(p);

            // Anything already on disk and matching its hash is left alone, so an interrupted
            // fetch resumes instead of downloading what it already has.
            if (scratch.alloc(u8, want)) |buf| {
                if (readPiece(f.meta, scratch, io, f.dest, p, buf)) |have| {
                    if (f.meta.verify(p, have)) |_| {
                        _ = @atomicRmw(usize, &f.resumed, .Add, 1, .monotonic);
                        f.finish(p, true, io);
                        continue;
                    } else |_| {}
                } else |_| {}
            } else |_| {}

            var attempt: usize = 0;
            var last_err: []const u8 = "unknown";
            const ok = while (attempt <= f.retries) : (attempt += 1) {
                // The salt is the downloader's own cache-buster, used only after a bad piece.
                var salt: [12]u8 = undefined;
                const s: ?[]const u8 = if (attempt == 0) null else blk: {
                    const alpha = "abcdefghijklmnopqrstuvwxyz1234567890";
                    var prng = std.Random.DefaultPrng.init(@as(u64, p) *% 1000003 +% attempt);
                    for (&salt) |*c| c.* = alpha[prng.random().uintLessThan(usize, alpha.len)];
                    break :blk salt[0..];
                };
                // Each retry moves to the next server whose range covers this piece, so a
                // mirror that is down costs one attempt rather than every attempt.
                const url = f.meta.pieceUrlFrom(scratch, p, s, attempt) catch continue;
                const body = fetchUrl(scratch, &client, url) catch |e| {
                    last_err = if (e == error.HttpStatus)
                        std.fmt.allocPrint(scratch, "HTTP {d}", .{last_status}) catch "HttpStatus"
                    else
                        @errorName(e);
                    continue;
                };
                if (body.len != want) {
                    last_err = "short read";
                    continue;
                }
                f.meta.verify(p, body) catch {
                    last_err = "hash mismatch";
                    continue;
                };
                writePiece(f.meta, scratch, io, f.dest, p, body) catch |e| {
                    last_err = @errorName(e);
                    continue;
                };
                break true;
            } else false;

            f.finish(p, ok, io);
            if (!ok) {
                std.debug.print("\n  piece {d}: {s} after {d} tries\n", .{ p, last_err, f.retries + 1 });
                // One failure is a blip; a wall of them with nothing succeeding means the CDN
                // is refusing us, and grinding through thousands of pieces to learn that
                // helps nobody.
                if (@atomicLoad(usize, &f.failed, .monotonic) >= 8 and
                    @atomicLoad(usize, &f.done, .monotonic) == 0)
                {
                    @atomicStore(bool, &f.gave_up, true, .monotonic);
                    return;
                }
            }
        }
    }

    fn finish(f: *Fetch, piece: usize, ok: bool, io: std.Io) void {
        if (ok) _ = @atomicRmw(usize, &f.done, .Add, 1, .monotonic) else _ = @atomicRmw(usize, &f.failed, .Add, 1, .monotonic);

        const done = @atomicLoad(usize, &f.done, .monotonic);
        const failed = @atomicLoad(usize, &f.failed, .monotonic);
        if (f.grid) |g| {
            g.mark(piece - f.from, ok);
            g.io = io;
            g.draw(done, failed, !ok);
        } else if (done % 25 == 0 or piece == f.last) {
            std.debug.print("\r  {d}/{d} pieces", .{ done, f.order.len });
        }
    }
};

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
threadlocal var last_status: u16 = 0;

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
