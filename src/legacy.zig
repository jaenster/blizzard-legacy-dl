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

pub const Metainfo = struct {
    /// The whole stub, borrowed; every slice below points into it.
    raw: []const u8,
    /// Where the bencoded torrent sits inside the stub.
    at: usize,
    end: usize,

    announce: []const u8,
    /// The HTTP piece source. This is the one that still works.
    direct_download: []const u8,
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

    /// `<base>/<index>`. On a retry the downloader appends `?<shuffled alphabet>` purely to miss
    /// the CDN cache; `salt` reproduces that when a piece comes back corrupt.
    pub fn pieceUrl(self: Metainfo, gpa: std.mem.Allocator, index: usize, salt: ?[]const u8) ![]u8 {
        return if (salt) |s|
            std.fmt.allocPrint(gpa, "{s}/{d}?{s}", .{ self.direct_download, index, s })
        else
            std.fmt.allocPrint(gpa, "{s}/{d}", .{ self.direct_download, index });
    }

    pub fn verify(self: Metainfo, index: usize, data: []const u8) Error!void {
        if (data.len != self.pieceSize(index)) return Error.ShortPiece;
        var got: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &got, .{});
        if (!std.mem.eql(u8, &got, self.pieceHash(index))) return Error.PieceHashMismatch;
    }
};

/// Find and decode the torrent embedded in a downloader stub.
pub fn fromStub(gpa: std.mem.Allocator, exe: []const u8) !Metainfo {
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

        return .{
            .raw = exe,
            .at = at,
            .end = r[1],
            .announce = root.str_("announce") orelse "",
            .direct_download = root.str_("direct download") orelse "",
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
