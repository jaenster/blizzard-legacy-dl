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
const keystore = @import("libd2").bnet.keystore;
const cdkey = @import("libd2").bnet.cdkey;

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
    \\                 install keeps its payloads in a cache shared by every version:
    \\                 $BLIZZARD_LEGACY_DL_CACHE, else $XDG_CACHE_HOME or ~/.cache, under
    \\                 blizzard-legacy-dl/. -o overrides it; fetch and run still use the cwd.
    \\  --no-base      install an expansion on its own, without its base game first
    \\  --version <v>  install an older version, e.g. 1.09b (or give it as the 3rd argument)
    \\  --cdkey <key>  the classic CD key, stored where the game keeps it
    \\  --cdkey-expansion <key>
    \\                 the expansion key; the two are different keys
    \\  --owner <name> the account name stored beside them
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

/// Where payloads live when nobody says otherwise. A payload for a given product and locale never
/// changes, so every install of every version can share one copy.
fn cacheDir(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) ![]const u8 {
    const base = env.get("BLIZZARD_LEGACY_DL_CACHE") orelse
        env.get("XDG_CACHE_HOME") orelse
        env.get("LOCALAPPDATA") orelse
        if (env.get("HOME")) |home|
            try std.fmt.allocPrint(gpa, "{s}/.cache", .{home})
        else
            return ".";
    const dir = try std.fmt.allocPrint(gpa, "{s}/blizzard-legacy-dl", .{base});
    mkdirs(io, dir) catch return ".";
    return dir;
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
    var secrets: Secrets = .{};
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
        } else if (std.mem.eql(u8, a, "--cdkey") and i + 1 < argv.len) {
            i += 1;
            secrets.classic = argv[i];
            checkKey("classic", argv[i]);
        } else if (std.mem.eql(u8, a, "--cdkey-expansion") and i + 1 < argv.len) {
            i += 1;
            secrets.expansion = argv[i];
            checkKey("expansion", argv[i]);
        } else if (std.mem.eql(u8, a, "--owner") and i + 1 < argv.len) {
            i += 1;
            secrets.owner = argv[i];
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
    //
    // Not for `install`, though: there the payload is scratch on the way to a game directory, and
    // running the command from somewhere else should not mean fetching the same immutable gigabyte
    // and a half again. Those go to a cache, which every install shares.
    const dir_path = out_dir orelse if (std.mem.eql(u8, verb, "install")) try cacheDir(gpa, init.io, init.environ_map) else ".";

    // An expansion installs over its base game, so asking to install one means installing both,
    // base first. Only `install` does this: fetching an expansion on its own is a fine thing to
    // want, and `run` walks one payload by definition.
    var code_buf: [8]u8 = undefined;
    const code = if (argv[2].len <= code_buf.len) blk: {
        for (argv[2], 0..) |c, k| code_buf[k] = std.ascii.toUpper(c);
        break :blk code_buf[0..argv[2].len];
    } else argv[2];
    const both = std.mem.eql(u8, verb, "install") and !no_base;
    const targets: []const []const u8 =
        if (both and std.mem.eql(u8, code, "D2XP")) &.{ "D2DV", "D2XP" } else if (both and std.mem.eql(u8, code, "W3XP")) &.{ "WAR3", "W3XP" } else &.{argv[2]};

    // Both halves land in one game directory, named for what was actually asked for.
    const game_root = game_dir orelse try std.fmt.allocPrint(gpa, "{s}/{s}-game", .{ dir_path, meta.name });

    for (targets, 0..) |target, pass| {
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

        if (std.mem.eql(u8, verb, "install")) try install(gpa, init.io, dest, game_root, platform, language, if (pass + 1 == targets.len) want_version else null, patch_source, secrets, &client);
    } // end of the per-product loop
}

/// The archives an install lays down, in the order the game searches them. `patch_d2.mpq` is not
/// among them: the patch rebuilds that one outright.
const installed_archives = [_][]const u8{
    "d2exp.mpq",  "d2xtalk.mpq", "d2xmusic.mpq", "d2xvideo.mpq", "d2data.mpq",
    "d2char.mpq", "d2sfx.mpq",   "d2music.mpq",  "d2speech.mpq", "d2video.mpq",
};

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
    var unchanged: usize = 0;
    if (disk_map) |text| {
        for (try ptc.parseMap(gpa, text)) |m| {
            // A file the patch does not carry is one it does not change; the installed copy stays.
            const rec_bytes = patch.read(gpa, m.member) catch {
                unchanged += 1;
                continue;
            };
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
    var short: usize = 0;
    if (patch.read(gpa, "patch.lst")) |lst| {
        // Here the pair is the other way round: archive path first, member second.
        const Wanted = struct { name: []const u8, rec: ptc.Record, data: ?[]const u8 };
        var want: std.ArrayList(Wanted) = .empty;
        var deltas: usize = 0;
        for (try ptc.parseMap(gpa, lst)) |m| {
            const bytes = patch.read(gpa, m.destination) catch continue;
            const rec = ptc.Record.parse(bytes) catch continue;
            if (rec.src_size == 0) {
                const body = ptc.apply(gpa, rec, &[_]u8{}) catch continue;
                try want.append(gpa, .{ .name = m.member, .rec = rec, .data = body });
            } else {
                deltas += 1;
                try want.append(gpa, .{ .name = m.member, .rec = rec, .data = null });
            }
        }

        // Most members of patch_d2.mpq are deltas against the file the game reads today, so the
        // source comes out of the installed archives — `data\global\excel\armor.bin` against the
        // copy in d2exp.mpq, and so on. They are searched in the game's own order, one at a time so
        // that a quarter-gigabyte archive is never held for longer than it is being read, and
        // patch_d2.mpq is not among them: the script deletes it before any of this.
        for (installed_archives) |archive_name| {
            if (deltas == 0) break;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, archive_name });
            defer gpa.free(path);
            const bytes = readFile(gpa, io, path) catch continue;
            defer gpa.free(bytes);
            var have = mpq.Archive.open(gpa, bytes) catch continue;
            defer have.deinit(gpa);
            for (want.items) |*w| {
                if (w.data != null) continue;
                const src = have.read(gpa, w.name) catch continue;
                defer gpa.free(src);
                w.data = ptc.apply(gpa, w.rec, src) catch continue;
                deltas -= 1;
            }
        }

        var members: std.ArrayList(mpq.NewFile) = .empty;
        for (want.items) |w| {
            if (w.data) |d| try members.append(gpa, .{ .name = w.name, .data = d }) else short += 1;
        }
        if (members.items.len != 0) {
            // Give it a `(listfile)`, which Blizzard's own patch_d2.mpq does not have. An archive
            // stores hashes rather than names, so one without a listfile cannot be enumerated at
            // all — and a tool that reduces an archive by walking its names silently produces an
            // EMPTY one instead of failing. We know every name here; writing them down costs a few
            // kilobytes and removes that whole class of quiet damage.
            var listing: std.Io.Writer.Allocating = .init(gpa);
            for (members.items) |m| {
                try listing.writer.writeAll(m.name);
                try listing.writer.writeAll("\r\n");
            }
            try members.append(gpa, .{ .name = "(listfile)", .data = listing.written() });

            var slots: u32 = 16;
            while (slots < members.items.len * 2) slots *= 2;
            const empty = try mpq.empty(gpa, slots);
            const built = try mpq.append(gpa, empty, members.items);
            const full = try std.fmt.allocPrint(gpa, "{s}/patch_d2.mpq", .{game});
            try writeWhole(io, full, built);
            rebuilt = members.items.len - 1; // the listfile is ours, not one of the patch's members
        }
    } else |_| {}

    std.debug.print("  {d} files patched, {d} left as installed, patch_d2.mpq rebuilt with {d} members\n", .{ wrote, unchanged, rebuilt });
    if (short != 0) std.debug.print("  {d} members of patch_d2.mpq could not be rebuilt\n", .{short});

    // Only a version that ships its own Storm.dll reads the archives through it; 1.14 links its
    // archive code into Game.exe and reads everything the payload carries.
    if (fileExists(io, game, "Storm.dll")) {
        for (installed_archives) |archive_name| {
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, archive_name });
            defer gpa.free(path);
            const bytes = readFile(gpa, io, path) catch continue;
            defer gpa.free(bytes);
            if (!try unhookModernAttributes(gpa, bytes)) continue;
            try writeWhole(io, path, bytes);
            std.debug.print("  {s}: unlisted its (attributes), which this version's Storm.dll cannot read\n", .{archive_name});
        }
    }
}

fn fileExists(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buf: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    const f = openFile(io, full, .read_only) catch return false;
    f.close(io);
    return true;
}

/// What an `(attributes)` member may carry for the Storm.dll a pre-1.14 version ships: a CRC32 and
/// a FILETIME per block. Its loader sizes the member as 8 + 12 bytes a block and ignores
/// anything else.
const storm_dll_attributes: u32 = 0x1 | 0x2;

/// A hash-table slot whose member is gone. Unlike an empty slot, a lookup probes past it, so the
/// names that collided behind it stay reachable.
const deleted_slot: u32 = 0xFFFF_FFFE;

/// Take a 1.14-format `(attributes)` out of an archive's hash table, in place. True if there was
/// one to take.
///
/// Every older version is built from the 1.14b payload, and of the archives it carries only
/// `d2sfx.mpq` has its `(attributes)` in the 1.14 format: zlib-compressed with per-sector CRCs, and
/// carrying an MD5 per block besides. Its listfile is zlib too, but nothing reads that at startup. Storm.dll opens
/// `(attributes)` inside `SFileOpenArchive`, and the Storm.dll 1.13c ships decompresses Huffman,
/// PKWARE and the two ADPCM codecs and nothing else. A zlib sector falls through to Storm's fatal
/// error 0x85100083, reported against the archive:
///
///     This application has encountered a critical error: The file data is corrupt.
///     File: d2sfx.mpq
///
/// That reads as a damaged download, or as a missing CD key, and is neither. It is also not about
/// reading `(attributes)` too strictly: the same member would be discarded a moment later anyway,
/// because with the MD5 column it is not the 8 + 12-per-block size that loader accepts. So the
/// member is worth nothing to that engine, and only having it listed kills the boot.
///
/// The test is on the content rather than on the archive's name, so a `(attributes)` the old
/// Storm can use — the ones in `d2exp.mpq` and the other expansion archives, which carry only the
/// CRC32 and FILETIME columns — keeps its checksums. Only the hash entry changes; the bytes
/// stay where they are, unreferenced, and the archive keeps its size and every member its offset.
fn unhookModernAttributes(gpa: std.mem.Allocator, bytes: []u8) !bool {
    var arc = mpq.Archive.open(gpa, bytes) catch return false;
    defer arc.deinit(gpa);

    const attrs = arc.read(gpa, "(attributes)") catch return false;
    defer gpa.free(attrs);
    if (attrs.len < 8) return false;
    const carries = std.mem.readInt(u32, attrs[4..8], .little);
    if (carries & ~storm_dll_attributes == 0) return false;

    const mask: u32 = @intCast(arc.hashes.len - 1);
    const a = mpq.hashString("(attributes)", .name_a);
    const b = mpq.hashString("(attributes)", .name_b);
    var slot = mpq.hashString("(attributes)", .table_offset) & mask;
    var probes: u32 = 0;
    const found = while (probes <= mask) : (probes += 1) {
        const e = arc.hashes[slot];
        if (e.block_index == 0xFFFF_FFFF) return false;
        if (e.block_index != deleted_slot and e.name_a == a and e.name_b == b) break slot;
        slot = (slot + 1) & mask;
    } else return false;
    arc.hashes[found].block_index = deleted_slot;

    const table = bytes[arc.base + arc.header.hash_table_pos ..][0 .. arc.hashes.len * 16];
    for (arc.hashes, 0..) |e, i| {
        const r = table[i * 16 ..][0..16];
        std.mem.writeInt(u32, r[0..4], e.name_a, .little);
        std.mem.writeInt(u32, r[4..8], e.name_b, .little);
        std.mem.writeInt(u16, r[8..10], e.locale, .little);
        std.mem.writeInt(u16, r[10..12], e.platform, .little);
        std.mem.writeInt(u32, r[12..16], e.block_index, .little);
    }
    mpq.encrypt(table, mpq.hashString("(hash table)", .file_key));
    return true;
}

/// Build the game directory from a payload that has just been fetched.
///
/// The payload's archives hold both the files and the script saying where they go. Everything the
/// script asks for that has meaning off Windows is done; the registry keys, shortcuts and DirectX
/// bundle it also asks for are counted and reported instead.
/// The values the install script asks to be hidden inside the game's own archives: the CD keys
/// and the account name. None of them is a file the payload carries — the real installer prompts
/// for them and encrypts what it is told, which is why nothing here comes out of the Tome.
///
/// A key is per-product and the two are NOT interchangeable: classic and expansion are separate
/// keys, sixteen or twenty-six characters, written to different archives. The script says which
/// one each `encrypt` wants, so the caller supplies both and the manifest does the choosing.
const Secrets = struct {
    classic: ?[]const u8 = null,
    expansion: ?[]const u8 = null,
    owner: ?[]const u8 = null,

    fn any(self: Secrets) bool {
        return self.classic != null or self.expansion != null or self.owner != null;
    }

    /// What this `encrypt` should store, or null if the caller gave nothing for it. The owner name
    /// carries no product id, which is exactly how it is told apart from a key.
    fn textFor(self: Secrets, object: []const u8, product_id: ?u16) ?[]const u8 {
        if (std.mem.eql(u8, object, "user")) return self.owner;
        if (!std.mem.startsWith(u8, object, "cdkey")) return null;
        return switch (product_id orelse return null) {
            @intFromEnum(keystore.Product.classic) => self.classic,
            @intFromEnum(keystore.Product.expansion) => self.expansion,
            else => null,
        };
    }
};

/// Say so when a key is not one the game would accept, rather than writing it and leaving the
/// rejection to happen later at a Battle.net login with nothing pointing back here.
///
/// This warns rather than refuses. The check is ours, not the game's, and a private realm is free
/// to want a key that Blizzard's own numbering would not issue; refusing would block that for no
/// gain, while saying nothing would hide a typo until it costs an hour.
fn checkKey(kind: []const u8, key: []const u8) void {
    const ok = switch (key.len) {
        16 => cdkey.decode16(key) != null,
        26 => cdkey.decode26(key) != null,
        else => {
            std.debug.print("  !! the {s} key is {d} characters; a Diablo II key is 16 or 26\n", .{ kind, key.len });
            return;
        },
    };
    if (!ok) std.debug.print("  !! the {s} key does not decode — check it for a typo\n", .{kind});
}

fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
    game: []const u8,
    platform: []const u8,
    language: []const u8,
    version: ?[]const u8,
    patch_source: []const u8,
    secrets: Secrets,
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
    var hidden: usize = 0;
    var elsewhere: usize = 0;

    // Everything bound for an archive, gathered per container so each one is rewritten once.
    // Members and encrypted values go through the same door on purpose: they land in the same
    // archives, and a 250 MB archive rewritten twice for two kinds of write is 250 MB of waste.
    var bound: std.StringArrayHashMapUnmanaged(std.ArrayList(mpq.NewFile)) = .empty;
    const bind = struct {
        fn add(a: std.mem.Allocator, m: *std.StringArrayHashMapUnmanaged(std.ArrayList(mpq.NewFile)), container: []const u8, f: mpq.NewFile) !void {
            const slot = try m.getOrPut(a, container);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(a, f);
        }
    }.add;

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
        .add_to_archive => |a| {
            const from = a.file.from orelse continue;
            const data = set.read(gpa, from) catch continue;
            try bind(gpa, &bound, a.container, .{ .name = a.file.to, .data = data });
        },
        .encrypt => |e| {
            const container = e.container orelse {
                elsewhere += 1;
                continue;
            };
            const text = secrets.textFor(e.object, e.product_id) orelse {
                elsewhere += 1;
                continue;
            };
            // The wrapping password is fixed for every install on earth, so nothing about this
            // depends on the machine it runs on: the same key produces a blob any copy reads.
            const pw = keystore.blockKey();
            const blob = try gpa.alloc(u8, keystore.wrappedLen(text.len));
            keystore.encrypt(blob, text, &pw);
            try bind(gpa, &bound, container, .{ .name = e.into, .data = blob });
            std.debug.print("  storing {s} in {s}\n", .{ e.object, container });
            hidden += 1;
        },
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
    for (bound.keys(), bound.values()) |container, list| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, container });
        defer gpa.free(path);
        const before = readFile(gpa, io, path) catch continue;
        defer gpa.free(before);
        const grown = mpq.append(gpa, before, list.items) catch continue;
        defer gpa.free(grown);
        try writeWhole(io, path, grown);
        added += list.items.len;
    }

    std.debug.print("{d} files, {d} members added to installed archives, {d} steps only Windows can do\n", .{ wrote, added, elsewhere });
    if (secrets.any() and hidden == 0)
        std.debug.print("!! nothing was stored: this script asks for no value the given options supply\n", .{});

    if (version) |v| try patchTo(gpa, io, client, &set, game, v, found > 0 and set.has("PC-100x\\Game.exe"), patch_source);
    std.debug.print("the game is in {s}\n", .{game});
    if (version) |v| if (copyProtected(v)) std.debug.print(
        \\
        \\!! {s} will not start on current Windows, and nothing is missing from the install.
        \\   Its Game.exe is Blizzard's, wrapped in SafeDisc: the copy protection on every Diablo II
        \\   client before 1.12. It wants the play disc, read through a driver Windows 10 and later no
        \\   longer ship; without them it exits within seconds, with no window and exit code 2. 1.12a
        \\   and later carry no copy protection.
        \\
    , .{v});
}

/// Whether the Windows `Game.exe` of a version is wrapped in SafeDisc. Every client from 1.00 to
/// 1.11b is (sections `.cms_t`/`.cms_d`, later randomly named ones); 1.12a dropped the disc check
/// and with it the wrapper. Versions are written `1.09b`, so the two digits after `1.` decide.
fn copyProtected(version: []const u8) bool {
    if (!std.mem.startsWith(u8, version, "1.")) return false;
    var minor: u32 = 0;
    var digits: usize = 0;
    for (version[2..]) |c| {
        if (c < '0' or c > '9') break;
        minor = minor * 10 + (c - '0');
        digits += 1;
    }
    return digits != 0 and minor < 12;
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

test "every version before 1.12a is flagged as copy-protected, and none after" {
    for ([_][]const u8{ "1.00", "1.06b", "1.07", "1.09b", "1.09d", "1.10", "1.11b" }) |v|
        try std.testing.expect(copyProtected(v));
    for ([_][]const u8{ "1.12a", "1.13c", "1.13d", "1.14b", "1.14d", "", "1.", "2.4" }) |v|
        try std.testing.expect(!copyProtected(v));
}

test "only an (attributes) the old Storm.dll cannot use is unlisted, and nothing else moves" {
    const gpa = std.testing.allocator;
    const Case = struct { carries: u32, unlisted: bool };
    for ([_]Case{
        .{ .carries = 0x7, .unlisted = true }, // CRC32, FILETIME and MD5, as the 1.14 d2sfx.mpq has
        .{ .carries = 0x3, .unlisted = false }, // CRC32 and FILETIME, as d2exp.mpq has
    }) |case| {
        var attrs: [8]u8 = undefined;
        std.mem.writeInt(u32, attrs[0..4], 100, .little);
        std.mem.writeInt(u32, attrs[4..8], case.carries, .little);

        const empty = try mpq.empty(gpa, 16);
        defer gpa.free(empty);
        const built = try mpq.append(gpa, empty, &.{
            .{ .name = "data\\global\\sfx\\cursor\\button.wav", .data = "RIFF" },
            .{ .name = "(attributes)", .data = &attrs },
        });
        defer gpa.free(built);
        const before = try gpa.dupe(u8, built);
        defer gpa.free(before);

        try std.testing.expectEqual(case.unlisted, try unhookModernAttributes(gpa, built));
        try std.testing.expectEqual(before.len, built.len);

        var arc = try mpq.Archive.open(gpa, built);
        defer arc.deinit(gpa);
        try std.testing.expectEqual(!case.unlisted, arc.lookup("(attributes)") != null);
        const wav = try arc.read(gpa, "data\\global\\sfx\\cursor\\button.wav");
        defer gpa.free(wav);
        try std.testing.expectEqualStrings("RIFF", wav);
        // Everything outside the hash table is untouched.
        const table_at = arc.base + arc.header.hash_table_pos;
        try std.testing.expectEqualSlices(u8, before[0..table_at], built[0..table_at]);
        const table_end = table_at + arc.hashes.len * 16;
        try std.testing.expectEqualSlices(u8, before[table_end..], built[table_end..]);
    }
}
