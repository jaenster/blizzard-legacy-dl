//! blizzard-legacy-dl — fetch what Blizzard's legacy downloader stub points at.
//!
//! See src/legacy.zig for how the HTTP piece source actually works. The short version: the
//! payload is served as one numbered file per BitTorrent piece, so pieces can be fetched in any
//! order, each is verifiable on its own, and there is no session or token to establish.

const std = @import("std");
const legacy = @import("legacy");
const installer = @import("installer.zig");
const proxy = @import("proxy.zig");
const cdkey = @import("libd2").bnet.cdkey;

const fetchUrl = installer.fetchUrl;
const mkdirs = installer.mkdirs;
const zpath = installer.zpath;
const createFile = installer.createFile;
const readFile = installer.readFile;

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

const getlegacy = installer.getlegacy;

const products = [_][]const u8{ "D2DV", "D2XP", "STAR", "WAR3", "W3XP" };
const locales = [_][]const u8{
    "en-US", "en-GB", "de-DE", "es-ES", "es-MX", "fr-FR", "it-IT",
    "ja-JP", "ko-KR", "pl-PL", "pt-BR", "ru-RU", "zh-CN", "zh-TW",
};

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
    var secrets: installer.Secrets = .{};
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
            const body = fetchUrl(gpa, &client, url, null) catch continue;
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

    var term: Term = .{ .gpa = gpa, .io = init.io, .tty = std.Io.File.stderr().isTty(init.io) catch false };
    const progress: installer.Progress = .{ .ctx = &term, .report = Term.report };
    term.rep = .init(progress);

    // The payload is scratch on the way to a game directory, and running the command from
    // somewhere else should not mean fetching the same immutable gigabyte and a half again, so
    // install keeps payloads in a cache every install shares. An expansion installs over its base
    // game, so asking for one installs both, base first.
    if (std.mem.eql(u8, verb, "install")) {
        return installer.install(std.heap.smp_allocator, init.io, .{
            .product = argv[2],
            .version = want_version,
            .game_dir = game_dir orelse "",
            .cache_dir = out_dir,
            .locale = locale,
            .os = os_,
            .jobs = @intCast(@min(jobs, 255)),
            .patch_source = patch_source,
            .progress = progress,
            .secrets = secrets,
            .no_base = no_base,
            .platform = if (std.mem.eql(u8, platform, "macos")) .macos else .win32,
            .language = language,
            .base_url = base,
            .cookie = cookie_override,
            .retries = retries,
            .sequential = sequential,
            .first_piece = from,
            .last_piece = to,
        });
    }

    var cookie: ?[]const u8 = null;
    const stub = try installer.resolveStub(gpa, init.io, &client, argv[2], locale, os_, &term.rep);
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
            if (fetchUrl(gpa, &client, url, cookie)) |body| {
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
            if (fetchUrl(gpa, &client, url, cookie)) |body| {
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
    const last = to orelse meta.pieceCount() - 1;

    // The payload's own top-level directory, so an assembled tree matches what the stub expects
    // to launch.
    const dest = try zpath(gpa, &.{ dir_path, meta.name });
    try installer.preallocate(gpa, init.io, meta, dest);

    if (std.mem.eql(u8, verb, "verify")) {
        var bad: usize = 0;
        var buf = try gpa.alloc(u8, meta.piece_length);
        var p = from;
        while (p <= last) : (p += 1) {
            const want = meta.pieceSize(p);
            const got = installer.readPiece(meta, gpa, init.io, dest, p, buf[0..want]) catch "";
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

    const got = try installer.fetchPayload(gpa, init.io, meta, dest, .{
        .first = from,
        .last = last,
        .retries = retries,
        .jobs = jobs,
        .sequential = sequential,
        .cookie = cookie,
        .label = dir_path,
    }, &term.rep);

    if (std.mem.eql(u8, verb, "run")) {
        // The client announces exactly twice, started and stopped, and the second one claims
        // the download finished whether it did or not.
        if (!no_tracker and meta.announce.len != 0) {
            const pid = legacy.peerId(@bitCast(@as(i64, @intCast(meta.total))));
            const url = try legacy.announceUrl(gpa, meta.announce, meta.infohash, pid, "0", .stopped);
            std.debug.print("8  tracker       event=stopped\n", .{});
            if (fetchUrl(gpa, &client, url, cookie)) |_| {} else |_| {}
        } else {
            std.debug.print("8  tracker       skipped\n", .{});
        }
        // The client would run this itself. Printing it is as far as this goes: fetching a
        // payload is one thing, executing it unasked is another.
        std.debug.print("9  launch target {s}/{s}  (not run)\n", .{ dir_path, meta.launch_target });
    }

    if (got.failed != 0) return error.Incomplete;
}

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

/// The terminal side of the library's progress: the piece map (or a plain counter when stderr is
/// not a terminal) and every line of text, printed as it arrives.
const Term = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tty: bool,
    rep: installer.Reporter = .init(null),
    grid: ?Grid = null,
    done: usize = 0,
    failed: usize = 0,

    fn report(ctx: ?*anyopaque, ev: installer.Event) void {
        const t: *Term = @ptrCast(@alignCast(ctx.?));
        if (ev.pieces) |p| {
            if (p.index) |index| {
                t.done = p.done;
                t.failed = p.failed;
                if (t.grid) |*g| {
                    g.mark(index - p.first, p.ok);
                    g.draw(p.done, p.failed, !p.ok);
                } else if (p.done % 25 == 0 or index == p.first + p.count - 1) {
                    std.debug.print("\r  {d}/{d} pieces", .{ p.done, p.count });
                }
            } else {
                // The map only makes sense on a terminal; piped or in CI it would be a wall of
                // escapes.
                t.done = 0;
                t.failed = 0;
                t.grid = if (t.tty) Grid.init(t.gpa, t.io, p.count) catch null else null;
            }
        } else if (ev.message.len != 0 and ev.stage == .downloading) {
            // The closing line of a download goes under a final, complete map.
            if (t.grid) |*g| g.draw(t.done, t.failed, true);
        }
        if (ev.message.len != 0) std.debug.print("{s}", .{ev.message});
    }
};
