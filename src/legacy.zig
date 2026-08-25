//! Reading Blizzard's legacy downloader, and fetching what it points at.
//!
//! `https://www.battle.net/download/getLegacy?product=D2DV&locale=en-US&os=WIN` hands back a
//! ~2.7 MB stub. The stub is a BitTorrent client, and the torrent is bencoded inside the
//! executable itself. Its tracker (`*.tracker.worldofwarcraft.com:3724`) stopped answering years
//! ago, so every real download now runs over the `direct download` HTTP source instead.
//!
//! The thing worth knowing, and the reason a plain `curl` of the base URL gets you nowhere: the
//! HTTP source does not serve the payload as files, and not as one ranged stream. It serves
//! **one numbered file per BitTorrent piece** — `<base>/0`, `<base>/1`, ... `<base>/<n-1>` — and
//! the client plugs those into the same piece machinery it uses for peers. So pieces arrive in
//! whatever order the picker asks for, each one is independently verifiable against the SHA-1 in
//! the metainfo, and fetching them in parallel is free.
//!
//! Established by reverse engineering `Blizzard Downloader 2.2.0.1285`:
//! `HttpDirect_RequestPiece` -> `HttpWinInet_SendRequest`, which goes through WinInet, not the
//! `Http-get.cpp` socket path. That matters because the two send different agents — the socket
//! path is the tracker's and says `Blizzard Downloader 2.2`; the piece path comes from
//! `InternetOpenA("Blizzard Web Client", ...)`.

const std = @import("std");

pub const Error = error{
    NoTorrent,
    BadBencode,
    MissingKey,
    NotAPieceCount,
    PieceHashMismatch,
    ShortPiece,
};

/// The exact agent the piece fetcher identifies as. Not the tracker's agent.
pub const user_agent = "Blizzard Web Client";

// ── bencode ──────────────────────────────────────────────────────────────────────────────────

pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    list: []Value,
    dict: []Pair,

    pub const Pair = struct { key: []const u8, val: Value };

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .dict) return null;
        for (self.dict) |p| if (std.mem.eql(u8, p.key, key)) return p.val;
        return null;
    }
    pub fn str_(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return if (v == .str) v.str else null;
    }
    pub fn int_(self: Value, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return if (v == .int) v.int else null;
    }
};

/// Decode one value at `at`. Returns the value and the index just past it, so a caller can find
/// the exact byte range a sub-dictionary occupied — which is what hashing `info` requires.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, at: usize) Error!struct { Value, usize } {
    if (at >= bytes.len) return Error.BadBencode;
    switch (bytes[at]) {
        'i' => {
            const e = std.mem.indexOfScalarPos(u8, bytes, at, 'e') orelse return Error.BadBencode;
            const n = std.fmt.parseInt(i64, bytes[at + 1 .. e], 10) catch return Error.BadBencode;
            return .{ .{ .int = n }, e + 1 };
        },
        'l' => {
            var items: std.ArrayList(Value) = .empty;
            var i = at + 1;
            while (i < bytes.len and bytes[i] != 'e') {
                const r = try decode(gpa, bytes, i);
                items.append(gpa, r[0]) catch return Error.BadBencode;
                i = r[1];
            }
            if (i >= bytes.len) return Error.BadBencode;
            return .{ .{ .list = items.toOwnedSlice(gpa) catch return Error.BadBencode }, i + 1 };
        },
        'd' => {
            var pairs: std.ArrayList(Value.Pair) = .empty;
            var i = at + 1;
            while (i < bytes.len and bytes[i] != 'e') {
                const k = try decode(gpa, bytes, i);
                if (k[0] != .str) return Error.BadBencode;
                const v = try decode(gpa, bytes, k[1]);
                pairs.append(gpa, .{ .key = k[0].str, .val = v[0] }) catch return Error.BadBencode;
                i = v[1];
            }
            if (i >= bytes.len) return Error.BadBencode;
            return .{ .{ .dict = pairs.toOwnedSlice(gpa) catch return Error.BadBencode }, i + 1 };
        },
        else => {
            const c = std.mem.indexOfScalarPos(u8, bytes, at, ':') orelse return Error.BadBencode;
            const n = std.fmt.parseInt(usize, bytes[at..c], 10) catch return Error.BadBencode;
            if (c + 1 + n > bytes.len) return Error.BadBencode;
            return .{ .{ .str = bytes[c + 1 ..][0..n] }, c + 1 + n };
        },
    }
}

// ── the metainfo the stub carries ────────────────────────────────────────────────────────────

pub const File = struct { length: u64, path: []const u8 };

/// One HTTP piece source, and the pieces it is allowed to serve.
///
/// The downloader keeps a vector of these and picks the first whose range covers the piece it
/// wants, sticking with a server while its throughput holds up. A plain `direct download` URL
/// covers everything; a `server list` entry covers only `begin..end`.
pub const Server = struct {
    url: []const u8,
    first: u64 = 0,
    last: u64 = std.math.maxInt(u64),

    pub fn covers(self: Server, index: usize) bool {
        return index >= self.first and index <= self.last;
    }
};

/// Expand one `direct download` string into every server URL it names.
///
/// Faithful to DirectDownload_ExpandServerUrls in the downloader, whose delimiters were read
/// off the `MOV DL,imm` at each split call site:
///
///   * the string splits on `|`, so one entry may name several URLs;
///   * a URL not starting with `http://`, or with no `[...]` group before the first `/` after
///     the host, is taken verbatim;
///   * otherwise the bracket body splits on `,`, each item splits on `-`, and a two-part item
///     is the inclusive integer range `a..b`;
///   * each integer N yields `prefix ++ N ++ path`, where `path` starts at the first `/` after
///     the host — so any host text between `]` and the path is dropped, which means the bracket
///     is meant to end the hostname.
///
/// So `http://dl[1-3,7].example/x` is four servers. None of Blizzard's own stubs use any of
/// this — every one carries a single bracket-free URL — but the client accepts it, so a mirror
/// can hand out a whole fleet in one string.
pub fn expandServerUrls(gpa: std.mem.Allocator, spec: []const u8, out: *std.ArrayList(Server)) !void {
    var urls = std.mem.splitScalar(u8, spec, '|');
    while (urls.next()) |url| {
        if (url.len == 0) continue;
        if (!std.mem.startsWith(u8, url, "http://")) {
            try out.append(gpa, .{ .url = url });
            continue;
        }
        // The bracket has to sit in the host, before the path begins.
        const path_at = std.mem.indexOfScalarPos(u8, url, 8, '/') orelse {
            try out.append(gpa, .{ .url = url });
            continue;
        };
        const open = std.mem.indexOfScalarPos(u8, url, 8, '[') orelse 0;
        const close = std.mem.indexOfScalarPos(u8, url, 8, ']') orelse 0;
        if (open == 0 or close == 0 or open >= path_at or close >= path_at or close < open) {
            try out.append(gpa, .{ .url = url });
            continue;
        }

        const prefix = url[0..open];
        const path = url[path_at..];
        var items = std.mem.splitScalar(u8, url[open + 1 .. close], ',');
        while (items.next()) |item| {
            var ends = std.mem.splitScalar(u8, item, '-');
            const a_txt = ends.next() orelse continue;
            const a = std.fmt.parseInt(u64, a_txt, 10) catch continue;
            const b = if (ends.next()) |b_txt|
                std.fmt.parseInt(u64, b_txt, 10) catch a
            else
                a;
            var n = a;
            while (n <= b) : (n += 1) {
                try out.append(gpa, .{
                    .url = try std.fmt.allocPrint(gpa, "{s}{d}{s}", .{ prefix, n, path }),
                });
            }
        }
    }
}

pub const Metainfo = struct {
    /// The whole stub, borrowed; every slice below points into it.
    raw: []const u8,
    /// Where the bencoded torrent sits inside the stub.
    at: usize,
    end: usize,

    announce: []const u8,
    /// The `direct download` value exactly as the torrent carries it, before expansion.
    direct_download: []const u8,
    /// Every HTTP piece source, in the order the client would consider them: the expansion of
    /// `direct download` first, then each `server list` entry with its piece range.
    servers: []Server,
    locale: []const u8,
    launch_target: []const u8,
    name: []const u8,
    piece_length: u64,
    /// Concatenated 20-byte SHA-1 digests, one per piece.
    pieces: []const u8,
    files: []File,
    total: u64,
    infohash: [20]u8,

    pub fn pieceCount(self: Metainfo) usize {
        return self.pieces.len / 20;
    }
    pub fn pieceHash(self: Metainfo, index: usize) *const [20]u8 {
        return self.pieces[index * 20 ..][0..20];
    }
    /// The last piece is short whenever the payload is not a whole multiple of the piece size.
    pub fn pieceSize(self: Metainfo, index: usize) u64 {
        const at = @as(u64, index) * self.piece_length;
        return @min(self.piece_length, self.total - at);
    }

    /// The base to use for `index`: the first server whose range covers it, which is how the
    /// client chooses. `attempt` walks past servers already tried, so a piece that fails on one
    /// mirror is retried on the next rather than hammering the same host.
    pub fn serverFor(self: Metainfo, index: usize, attempt: usize) ?Server {
        var seen: usize = 0;
        for (self.servers) |s| {
            if (!s.covers(index)) continue;
            if (seen == attempt) return s;
            seen += 1;
        }
        // Past the end, fall back to the first that covers it.
        for (self.servers) |s| if (s.covers(index)) return s;
        return null;
    }

    /// `<base>/<index>`. On a retry the downloader appends `?<shuffled alphabet>` purely to miss
    /// the CDN cache; `salt` reproduces that when a piece comes back corrupt.
    pub fn pieceUrl(self: Metainfo, gpa: std.mem.Allocator, index: usize, salt: ?[]const u8) ![]u8 {
        return self.pieceUrlFrom(gpa, index, salt, 0);
    }

    pub fn pieceUrlFrom(self: Metainfo, gpa: std.mem.Allocator, index: usize, salt: ?[]const u8, attempt: usize) ![]u8 {
        const base = if (self.serverFor(index, attempt)) |s|
            std.mem.trimEnd(u8, s.url, "/")
        else
            self.direct_download;
        return if (salt) |s|
            std.fmt.allocPrint(gpa, "{s}/{d}?{s}", .{ base, index, s })
        else
            std.fmt.allocPrint(gpa, "{s}/{d}", .{ base, index });
    }

    pub fn verify(self: Metainfo, index: usize, data: []const u8) Error!void {
        if (data.len != self.pieceSize(index)) return Error.ShortPiece;
        var got: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &got, .{});
        if (!std.mem.eql(u8, &got, self.pieceHash(index))) return Error.PieceHashMismatch;
    }
};

/// The Mac stub is a zip of an .app bundle, and its torrent is a separate compressed member
/// rather than bytes sitting in the executable — so scanning the raw file finds nothing. Pull
/// the member out before looking.
fn torrentFromZip(gpa: std.mem.Allocator, zip: []const u8) ?[]u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, zip, at, "PK\x03\x04")) |h| {
        at = h + 4;
        if (h + 30 > zip.len) break;
        const method = std.mem.readInt(u16, zip[h + 8 ..][0..2], .little);
        const csize = std.mem.readInt(u32, zip[h + 18 ..][0..4], .little);
        const usize_ = std.mem.readInt(u32, zip[h + 22 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, zip[h + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip[h + 28 ..][0..2], .little);
        const name_at = h + 30;
        if (name_at + name_len > zip.len) break;
        const name = zip[name_at..][0..name_len];
        const data_at = name_at + name_len + extra_len;
        if (data_at + csize > zip.len) continue;
        if (!std.mem.endsWith(u8, name, ".torrent")) continue;

        const src = zip[data_at..][0..csize];
        if (method == 0) return gpa.dupe(u8, src) catch null;
        if (method != 8) continue;
        const out = gpa.alloc(u8, usize_) catch return null;
        var in = std.Io.Reader.fixed(src);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var d = std.compress.flate.Decompress.init(&in, .raw, &window);
        const n = d.reader.readSliceShort(out) catch return null;
        return out[0..n];
    }
    return null;
}

/// Find and decode the torrent a downloader stub carries. Accepts a Windows .exe (bencode inside
/// the image), a Mac .zip (a `.torrent` member in the .app bundle), or a plain .torrent.
pub fn fromStub(gpa: std.mem.Allocator, stub: []const u8) !Metainfo {
    const exe = if (std.mem.startsWith(u8, stub, "PK\x03\x04"))
        torrentFromZip(gpa, stub) orelse return Error.NoTorrent
    else
        stub;
    // Every one of these starts its dictionary with the announce key; scanning for that is more
    // robust than trusting a section layout that varies between the Windows and Mac stubs.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, exe, search, "d8:announce")) |at| {
        search = at + 1;
        const r = decode(gpa, exe, at) catch continue;
        const root = r[0];
        const info = root.get("info") orelse continue;
        if (info != .dict) continue;

        // Hash the info dictionary over its ORIGINAL bytes — re-encoding it would have to
        // reproduce Blizzard's key order exactly, and a mismatch there is a silent wrong answer.
        const key = "4:infod";
        const ki = std.mem.indexOfPos(u8, exe, at, key) orelse continue;
        const istart = ki + key.len - 1;
        const iend = (decode(gpa, exe, istart) catch continue)[1];
        var ih: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(exe[istart..iend], &ih, .{});

        var files: std.ArrayList(File) = .empty;
        var total: u64 = 0;
        if (info.get("files")) |fl| {
            if (fl == .list) for (fl.list) |f| {
                const len: u64 = @intCast(f.int_("length") orelse continue);
                const pv = f.get("path") orelse continue;
                var parts: std.ArrayList(u8) = .empty;
                if (pv == .list) for (pv.list, 0..) |seg, n| {
                    if (n != 0) try parts.append(gpa, '/');
                    if (seg == .str) try parts.appendSlice(gpa, seg.str);
                };
                try files.append(gpa, .{ .length = len, .path = try parts.toOwnedSlice(gpa) });
                total += len;
            };
        } else if (info.int_("length")) |l| {
            total = @intCast(l);
            try files.append(gpa, .{ .length = total, .path = info.str_("name") orelse "payload" });
        }

        // Both server sources, in the order the client reads them: the expansion of
        // `direct download`, covering every piece, then each `server list` entry with the
        // range it is limited to. An entry missing begin/end/url is skipped, as it is there.
        const dd = root.str_("direct download") orelse "";
        var servers: std.ArrayList(Server) = .empty;
        try expandServerUrls(gpa, dd, &servers);
        if (root.get("server list")) |sl| {
            if (sl == .list) {
                for (sl.list) |e| {
                    const url = e.str_("url") orelse continue;
                    const first = e.int_("begin") orelse continue;
                    const last = e.int_("end") orelse continue;
                    try servers.append(gpa, .{
                        .url = url,
                        .first = @intCast(first),
                        .last = @intCast(last),
                    });
                }
            }
        }

        return .{
            .raw = exe,
            .at = at,
            .end = r[1],
            .announce = root.str_("announce") orelse "",
            .direct_download = dd,
            .servers = try servers.toOwnedSlice(gpa),
            .locale = root.str_("locale") orelse "",
            .launch_target = root.str_("launch target") orelse "",
            .name = info.str_("name") orelse "",
            .piece_length = @intCast(info.int_("piece length") orelse return Error.MissingKey),
            .pieces = info.str_("pieces") orelse return Error.MissingKey,
            .files = try files.toOwnedSlice(gpa),
            .total = total,
            .infohash = ih,
        };
    }
    return Error.NoTorrent;
}

/// Which file, and where in it, a given byte of the payload belongs. Pieces do not respect file
/// boundaries — one piece routinely spans the end of one file and the start of the next.
pub const Span = struct { file: usize, offset: u64, len: u64 };

pub fn spansForPiece(self: Metainfo, gpa: std.mem.Allocator, index: usize) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var want = self.pieceSize(index);
    var at = @as(u64, index) * self.piece_length;
    var base: u64 = 0;
    for (self.files, 0..) |f, i| {
        if (want == 0) break;
        if (at < base + f.length) {
            const off = at - base;
            const n = @min(want, f.length - off);
            try out.append(gpa, .{ .file = i, .offset = off, .len = n });
            at += n;
            want -= n;
        }
        base += f.length;
    }
    return out.toOwnedSlice(gpa);
}

// ── tests ────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bencode round trips the shapes a metainfo uses" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try decode(a, "d3:cow3:moo4:spami-42e4:listli1ei2eee", 0);
    try testing.expectEqual(@as(usize, 37), r[1]);
    try testing.expectEqualStrings("moo", r[0].str_("cow").?);
    try testing.expectEqual(@as(i64, -42), r[0].int_("spam").?);
    const l = r[0].get("list").?;
    try testing.expectEqual(@as(usize, 2), l.list.len);
}

test "a piece that is not a whole piece long is the last one" {
    const m: Metainfo = .{
        .raw = "", .at = 0, .end = 0, .announce = "", .direct_download = "http://h/base",
        .servers = &.{},
        .locale = "", .launch_target = "", .name = "x",
        .piece_length = 100, .pieces = &[_]u8{0} ** 60, .files = &.{}, .total = 250,
        .infohash = undefined,
    };
    try testing.expectEqual(@as(usize, 3), m.pieceCount());
    try testing.expectEqual(@as(u64, 100), m.pieceSize(0));
    try testing.expectEqual(@as(u64, 50), m.pieceSize(2));
}

test "piece urls are the base plus an index, and a salt only on retry" {
    const gpa = testing.allocator;
    const m: Metainfo = .{
        .raw = "", .at = 0, .end = 0, .announce = "", .direct_download = "http://h/base",
        .servers = &.{},
        .locale = "", .launch_target = "", .name = "x",
        .piece_length = 100, .pieces = &[_]u8{0} ** 20, .files = &.{}, .total = 100,
        .infohash = undefined,
    };
    const a = try m.pieceUrl(gpa, 7, null);
    defer gpa.free(a);
    try testing.expectEqualStrings("http://h/base/7", a);
    const b = try m.pieceUrl(gpa, 7, "zqx");
    defer gpa.free(b);
    try testing.expectEqualStrings("http://h/base/7?zqx", b);
}

test "direct download expands the way the client expands it" {
    const gpa = testing.allocator;

    // A plain URL is one server, untouched.
    {
        var out: std.ArrayList(Server) = .empty;
        defer out.deinit(gpa);
        try expandServerUrls(gpa, "http://a.example/p", &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings("http://a.example/p", out.items[0].url);
        // and it covers every piece
        try testing.expect(out.items[0].covers(0));
        try testing.expect(out.items[0].covers(999_999));
    }

    // '|' separates whole URLs.
    {
        var out: std.ArrayList(Server) = .empty;
        defer out.deinit(gpa);
        try expandServerUrls(gpa, "http://a.example/p|http://b.example/q", &out);
        try testing.expectEqual(@as(usize, 2), out.items.len);
        try testing.expectEqualStrings("http://b.example/q", out.items[1].url);
    }

    // A bracket group is a range, a list, or both.
    {
        var out: std.ArrayList(Server) = .empty;
        defer {
            for (out.items) |s| gpa.free(s.url);
            out.deinit(gpa);
        }
        try expandServerUrls(gpa, "http://dl[1-3,7]/x", &out);
        try testing.expectEqual(@as(usize, 4), out.items.len);
        try testing.expectEqualStrings("http://dl1/x", out.items[0].url);
        try testing.expectEqualStrings("http://dl3/x", out.items[2].url);
        try testing.expectEqualStrings("http://dl7/x", out.items[3].url);
    }

    // The client rebuilds the URL as prefix + N + everything from the first '/', so any host
    // text sitting between ']' and the path is dropped. Quirk, not an accident: the bracket is
    // meant to end the hostname. Matched here so the behaviour cannot drift apart from it.
    {
        var out: std.ArrayList(Server) = .empty;
        defer {
            for (out.items) |s| gpa.free(s.url);
            out.deinit(gpa);
        }
        try expandServerUrls(gpa, "http://dl[1-2].example/x", &out);
        try testing.expectEqual(@as(usize, 2), out.items.len);
        try testing.expectEqualStrings("http://dl1/x", out.items[0].url);
    }

    // A bracket after the path starts is not a host group, so the URL is left alone.
    {
        var out: std.ArrayList(Server) = .empty;
        defer out.deinit(gpa);
        try expandServerUrls(gpa, "http://a.example/p[1-3]", &out);
        try testing.expectEqual(@as(usize, 1), out.items.len);
        try testing.expectEqualStrings("http://a.example/p[1-3]", out.items[0].url);
    }
}

test "a server only serves the pieces its range covers" {
    const gpa = testing.allocator;
    var servers = [_]Server{
        .{ .url = "http://all.example", .first = 0, .last = std.math.maxInt(u64) },
        .{ .url = "http://tail.example", .first = 100, .last = 200 },
    };
    const m: Metainfo = .{
        .raw = "",         .at = 0,             .end = 0,
        .announce = "",    .direct_download = "http://all.example",
        .servers = &servers,
        .locale = "",      .launch_target = "", .name = "",
        .piece_length = 4, .pieces = "",        .files = &.{},
        .total = 0,        .infohash = undefined,
    };

    // Attempt 0 is the first server that covers the piece; attempt 1 is the next one.
    try testing.expectEqualStrings("http://all.example", m.serverFor(150, 0).?.url);
    try testing.expectEqualStrings("http://tail.example", m.serverFor(150, 1).?.url);
    // Piece 5 is outside the second server's range, so there is no second choice for it.
    try testing.expectEqualStrings("http://all.example", m.serverFor(5, 1).?.url);

    const u = try m.pieceUrlFrom(gpa, 150, null, 1);
    defer gpa.free(u);
    try testing.expectEqualStrings("http://tail.example/150", u);
}

// ── tracker ──────────────────────────────────────────────────────────────────────────────────

/// Percent-escape a value for the announce query, escaping everything that is not unreserved.
/// The info hash and peer id are raw bytes, not text, so this has to be byte-wise.
pub fn urlEscape(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(gpa, c),
        else => try out.print(gpa, "%{X:0>2}", .{c}),
    };
    return out.toOwnedSlice(gpa);
}

pub const Event = enum { started, stopped };

/// The announce URL, built the way Tracker_BuildAnnounceUrl builds it.
///
/// Faithful down to the odd parts: the port is the literal "3724" rather than any port this
/// program listens on, and the progress figures are fixed rather than measured — `started`
/// always claims nothing done, `stopped` always claims everything done. The client never sends
/// `event=completed` or `compact=1`; both strings are in the binary with no reference to them.
pub fn announceUrl(
    gpa: std.mem.Allocator,
    announce: []const u8,
    infohash: [20]u8,
    peer_id: [20]u8,
    key: []const u8,
    event: Event,
) ![]u8 {
    const ih = try urlEscape(gpa, &infohash);
    defer gpa.free(ih);
    const pid = try urlEscape(gpa, &peer_id);
    defer gpa.free(pid);
    const k = try urlEscape(gpa, key);
    defer gpa.free(k);
    return std.fmt.allocPrint(gpa, "{s}?info_hash={s}&peer_id={s}&key={s}&port=3724" ++
        "&uploaded=0&downloaded={d}&left={d}&event={s}", .{
        announce,
        ih,
        pid,
        k,
        @as(u8, if (event == .started) 0 else 1),
        @as(u8, if (event == .started) 1 else 0),
        @tagName(event),
    });
}

/// A 20-byte peer id. The client derives one from a machine identifier and hex-encodes ten
/// bytes of it, falling back to twenty random bytes in [0x21,0xff] when that lookup fails.
/// Taking the fallback shape on purpose: it is a real path in the client and it does not put a
/// machine identifier on the wire.
pub fn peerId(seed: u64) [20]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var id: [20]u8 = undefined;
    for (&id) |*c| c.* = prng.random().intRangeAtMost(u8, 0x21, 0xff);
    return id;
}

pub const Announce = struct {
    /// Set when the tracker refused; everything else is meaningless then.
    failure: ?[]const u8 = null,
    warning: ?[]const u8 = null,
    interval: ?i64 = null,
    peers: usize = 0,
    /// Servers the tracker handed out, from `direct.url` and `direct."server list"`. This is the
    /// mechanism by which a live tracker can move the client onto different CDN hosts.
    servers: []Server = &.{},
    threshold: ?i64 = null,
};

/// Parse an announce reply the way Tracker_ParseAnnounceResponse parses it.
pub fn parseAnnounce(gpa: std.mem.Allocator, body: []const u8) !Announce {
    if (body.len == 0 or body[0] != 'd') return Error.NoTorrent;
    const root, _ = try decode(gpa, body, 0);

    var out: Announce = .{
        .failure = root.str_("failure reason"),
        .warning = root.str_("warning"),
        .interval = root.int_("interval"),
    };
    if (root.get("peers")) |p| out.peers = switch (p) {
        .list => p.list.len,
        .str => p.str.len / 6, // compact form, six bytes per peer
        else => 0,
    };

    if (root.get("direct")) |d| {
        out.threshold = d.int_("threshold");
        var servers: std.ArrayList(Server) = .empty;
        if (d.str_("url")) |u| try expandServerUrls(gpa, u, &servers);
        if (d.get("server list")) |sl| {
            if (sl == .list) for (sl.list) |e| {
                const url = e.str_("url") orelse continue;
                const first = e.int_("begin") orelse continue;
                const last = e.int_("end") orelse continue;
                try servers.append(gpa, .{
                    .url = url,
                    .first = @intCast(first),
                    .last = @intCast(last),
                });
            };
        }
        out.servers = try servers.toOwnedSlice(gpa);
    }
    return out;
}

test "the announce url is built the way the client builds it" {
    const gpa = testing.allocator;
    const ih: [20]u8 = .{0xAB} ** 20;
    const pid: [20]u8 = .{'a'} ** 20;
    const u = try announceUrl(gpa, "http://t.example/announce", ih, pid, "k1", .started);
    defer gpa.free(u);
    try testing.expect(std.mem.startsWith(u8, u, "http://t.example/announce?info_hash=%AB%AB"));
    try testing.expect(std.mem.indexOf(u8, u, "&peer_id=aaaaaaaaaaaaaaaaaaaa") != null);
    // The fixed parts: a literal port, and progress that is asserted rather than measured.
    try testing.expect(std.mem.endsWith(u8, u, "&port=3724&uploaded=0&downloaded=0&left=1&event=started"));

    const v = try announceUrl(gpa, "http://t.example/announce", ih, pid, "k1", .stopped);
    defer gpa.free(v);
    try testing.expect(std.mem.endsWith(u8, v, "&downloaded=1&left=0&event=stopped"));
}

test "a tracker can hand out its own download servers" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const body = "d8:intervali1800e6:direct" ++
        "d9:thresholdi5e3:url23:http://t1/p|http://t2/p" ++
        "11:server listld5:begini10e3:endi20e3:url9:http://m1eee" ++
        "5:peersle" ++
        "e";
    const r = try parseAnnounce(a, body);
    try testing.expectEqual(@as(i64, 1800), r.interval.?);
    try testing.expectEqual(@as(i64, 5), r.threshold.?);
    // two from the pipe-separated url, one ranged entry from the server list
    try testing.expectEqual(@as(usize, 3), r.servers.len);
    try testing.expectEqualStrings("http://t2/p", r.servers[1].url);
    try testing.expectEqual(@as(u64, 10), r.servers[2].first);
    try testing.expectEqual(@as(u64, 20), r.servers[2].last);
}

test "a tracker refusal is reported, not mistaken for success" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseAnnounce(arena.allocator(), "d14:failure reason9:no such te");
    try testing.expectEqualStrings("no such t", r.failure.?);
    try testing.expectEqual(@as(usize, 0), r.servers.len);
}
