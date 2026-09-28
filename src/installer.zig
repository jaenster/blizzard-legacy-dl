//! The install pipeline as a library: resolve a product's downloader stub, fetch and verify its
//! payload piece by piece, build the game directory from the payload's own install script, and
//! patch it to a chosen version.
//!
//! `install` is the whole thing. The pieces it is made of (`resolveStub`, `fetchPayload`,
//! `preallocate`, `readPiece`, `fetchUrl`) are public too, for callers that want one step.
//!
//! Nothing here writes to stderr. Everything worth telling a person arrives through
//! `Options.progress`, as `Event.message` text alongside the counters.

const std = @import("std");
const watch_mod = @import("watch");
pub const legacy = @import("legacy");
const libd2 = @import("libd2");
const mpq = libd2.formats.mpq;
const script = libd2.formats.installer;
const ptc = libd2.formats.ptc;
const keystore = libd2.bnet.keystore;

pub const Stage = enum { resolving, downloading, verifying, installing, patching, done };

pub const Event = struct {
    stage: Stage,
    /// Bytes (downloading, verifying) or steps (installing, patching) finished in this stage, for
    /// the current product. Never decreases between two events of the same stage and product.
    done: u64,
    /// Same unit; 0 when unknown.
    total: u64,
    /// The current file, member or piece label. Only valid during the callback.
    file: []const u8 = "",
    /// The product whose payload is being handled, e.g. "D2DV" or "D2XP".
    product: []const u8 = "",
    /// A line of text worth showing a person, exactly as the CLI prints it (it may start or end
    /// with a newline). Empty on a plain progress tick. Only valid during the callback.
    message: []const u8 = "",
    /// Downloading and verifying only: piece-level detail, for a piece map.
    pieces: ?Pieces = null,
};

pub const Pieces = struct {
    /// The piece this event is about; null on the event that opens the stage.
    index: ?usize = null,
    /// Whether that piece arrived and verified. False means it failed after every retry.
    ok: bool = true,
    /// Whether it was already on disk and verified, so nothing was fetched.
    resumed: bool = false,
    /// The range being fetched: pieces `first .. first + count - 1`.
    first: usize,
    count: usize,
    /// Pieces finished so far, and pieces given up on.
    done: usize = 0,
    failed: usize = 0,
};

/// Called from whichever thread made the progress: the fetch workers as well as the thread that
/// called `install`. Calls are serialised (never two at once), but the callback must still be
/// safe to run off the UI thread and should return quickly, because a fetch worker waits for it.
/// It is called once per finished piece while downloading and once per step otherwise, never per
/// byte.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    report: *const fn (ctx: ?*anyopaque, ev: Event) void,
};

/// Shared with a UI thread. paused: workers stop taking new pieces and wait (polling every
/// 100 ms) until it is cleared. cancelled: `install` returns error.Cancelled as soon as practical;
/// everything on disk stays resumable, and a later `install` picks up the pieces already there.
pub const Control = struct {
    paused: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
};

/// The values the install script asks to be hidden inside the game's own archives: the CD keys
/// and the account name. None of them is a file the payload carries — the real installer prompts
/// for them and encrypts what it is told, which is why nothing here comes out of the Tome.
///
/// A key is per-product and the two are NOT interchangeable: classic and expansion are separate
/// keys, sixteen or twenty-six characters, written to different archives. The script says which
/// one each `encrypt` wants, so the caller supplies both and the manifest does the choosing.
pub const Secrets = struct {
    classic: ?[]const u8 = null,
    expansion: ?[]const u8 = null,
    owner: ?[]const u8 = null,

    pub fn any(self: Secrets) bool {
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

pub const Platform = enum { win32, macos };

pub const Options = struct {
    /// A product code, or a path to a downloader stub, Mac .zip or .torrent on disk.
    product: []const u8 = "D2XP",
    /// null = the payload's own version.
    version: ?[]const u8 = "1.14d",
    /// Where the game goes. Empty = "<cache_dir>/<payload name>-game".
    game_dir: []const u8,
    /// Where payloads are kept. null = $BLIZZARD_LEGACY_DL_CACHE, else $XDG_CACHE_HOME,
    /// %LOCALAPPDATA% or ~/.cache, under blizzard-legacy-dl/.
    cache_dir: ?[]const u8 = null,
    locale: []const u8 = "en-US",
    jobs: u8 = 4,
    patch_source: []const u8 = "https://files.typeguru.nl/diablo/patches/pc",
    progress: ?Progress = null,
    control: ?*Control = null,

    /// CD keys and account name to store in the game's archives.
    secrets: Secrets = .{},
    /// Install an expansion on its own, without its base game first.
    no_base: bool = false,
    /// Which stub to ask Blizzard for: WIN or MAC.
    os: []const u8 = "WIN",
    /// Which branch of the install script to follow.
    platform: Platform = .win32,
    /// Which language branch of the install script to follow.
    language: []const u8 = "English",
    /// Fetch pieces from this mirror instead of the servers the stub names.
    base_url: ?[]const u8 = null,
    /// Override the CDN access token taken from the stub.
    cookie: ?[]const u8 = null,
    retries: usize = 3,
    /// Fetch pieces in order instead of shuffled.
    sequential: bool = false,
    first_piece: usize = 0,
    last_piece: ?usize = null,
};

pub const Error = error{
    Cancelled,
    NoSuchVersion,
    /// Neither a file nor a product Blizzard would hand a stub for.
    NoStub,
    /// The payload carries no Installer Tome.
    NoTome,
    /// The payload's Tome carries no install script.
    NoManifest,
    /// Every piece tried failed; usually an expired CDN token.
    AllPiecesFailed,
    /// Some pieces failed after every retry. Running again resumes.
    Incomplete,
};

/// Blizzard's own endpoint. `www.battle.net` bounces through `eu.battle.net` to get here, so go
/// straight to it. It rate-limits: back-to-back requests come back empty, which looks exactly
/// like a missing product until you slow down.
pub const getlegacy = "https://downloader.battle.net/download/getLegacy";

// ── progress plumbing ──────────────────────────────────────────────────────────────────────────

/// Serialises every call into the caller's callback and keeps the per-stage counters, so a text
/// message carries the same done/total as the tick before it.
pub const Reporter = struct {
    progress: ?Progress = null,
    product: []const u8 = "",
    lock: std.atomic.Value(bool) = .init(false),
    counters: [@typeInfo(Stage).@"enum".fields.len][2]u64 = @splat(.{ 0, 0 }),

    pub fn init(progress: ?Progress) Reporter {
        return .{ .progress = progress };
    }

    fn acquire(r: *Reporter) void {
        while (r.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(r: *Reporter) void {
        r.lock.store(false, .release);
    }

    /// Start a new product: every stage counts from zero again.
    fn begin(r: *Reporter, product: []const u8) void {
        r.acquire();
        defer r.release();
        r.product = product;
        r.counters = @splat(.{ 0, 0 });
    }

    /// Emit with the lock held.
    fn emitLocked(r: *Reporter, ev: Event) void {
        const p = r.progress orelse return;
        var e = ev;
        if (e.product.len == 0) e.product = r.product;
        p.report(p.ctx, e);
    }

    /// Set a stage's counters and emit a tick. `done` below the current value is raised to it.
    fn set(r: *Reporter, stage: Stage, done: u64, total: u64, file: []const u8) void {
        r.acquire();
        defer r.release();
        const c = &r.counters[@intFromEnum(stage)];
        c[0] = @max(c[0], done);
        c[1] = total;
        r.emitLocked(.{ .stage = stage, .done = c[0], .total = c[1], .file = file });
    }

    /// A line of text, under the stage's current counters.
    fn say(r: *Reporter, stage: Stage, comptime fmt: []const u8, args: anytype) void {
        if (r.progress == null) return;
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        r.acquire();
        defer r.release();
        const c = r.counters[@intFromEnum(stage)];
        r.emitLocked(.{ .stage = stage, .done = c[0], .total = c[1], .message = msg });
    }
};

fn isCancelled(control: ?*Control) bool {
    const c = control orelse return false;
    return c.cancelled.load(.acquire);
}

/// Wait out a pause, then fail if cancelled.
fn checkpoint(io: std.Io, control: ?*Control) error{Cancelled}!void {
    const c = control orelse return;
    while (c.paused.load(.acquire) and !c.cancelled.load(.acquire))
        io.sleep(.fromMilliseconds(100), .awake) catch {};
    if (c.cancelled.load(.acquire)) return error.Cancelled;
}

// ── files ──────────────────────────────────────────────────────────────────────────────────────

// Files go through `std.Io`: the POSIX calls this used before have no Windows counterpart,
// and the payload being a Windows installer makes that the one platform to support.
const File = std.Io.File;
const Dir = std.Io.Dir;

// Paths arrive both relative and absolute, and `Dir` splits those into different calls.
pub fn openFile(io: std.Io, path: []const u8, mode: Dir.OpenFileOptions.Mode) !File {
    return if (std.fs.path.isAbsolute(path))
        Dir.openFileAbsolute(io, path, .{ .mode = mode })
    else
        Dir.cwd().openFile(io, path, .{ .mode = mode });
}

pub fn createFile(io: std.Io, path: []const u8) !File {
    // `truncate = false` because the caller may be resuming into a file it preallocated on an
    // earlier run, and throwing those bytes away would restart the download.
    return if (std.fs.path.isAbsolute(path))
        Dir.createFileAbsolute(io, path, .{ .read = true, .truncate = false })
    else
        Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
}

pub fn zpath(gpa: std.mem.Allocator, parts: []const []const u8) ![:0]u8 {
    var b: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i != 0 and b.items.len != 0) try b.append(gpa, '/');
        try b.appendSlice(gpa, p);
    }
    return b.toOwnedSliceSentinel(gpa, 0);
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(v, 0);
}

/// Where payloads live when nobody says otherwise. A payload for a given product and locale never
/// changes, so every install of every version can share one copy.
pub fn defaultCacheDir(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const base = getenv("BLIZZARD_LEGACY_DL_CACHE") orelse
        getenv("XDG_CACHE_HOME") orelse
        getenv("LOCALAPPDATA") orelse
        if (getenv("HOME")) |home|
            try std.fmt.allocPrint(gpa, "{s}/.cache", .{home})
        else
            return ".";
    const dir = try std.fmt.allocPrint(gpa, "{s}/blizzard-legacy-dl", .{base});
    mkdirs(io, dir) catch return ".";
    return dir;
}

/// A relative path of plain names: no wildcard, variable, drive, stream or `..`.
pub fn plainRelative(rel: []const u8) bool {
    if (rel.len == 0 or rel[0] == '/') return false;
    if (std.mem.indexOfAny(u8, rel, "*?\"<>|:$%") != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
        for (part) |c| if (c < 0x20) return false;
    }
    return true;
}

test "a request that stalls is abandoned at its deadline" {
    // A server that accepts, reads the request and then says nothing.
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    const Srv = struct {
        fn run(s: *std.Io.net.Server, i: std.Io) void {
            var conn = s.accept(i) catch return;
            std.Io.sleep(i, .fromMilliseconds(1500), .awake) catch {};
            conn.close(i);
        }
    };
    const t = try std.Thread.spawn(.{}, Srv.run, .{ &server, io });
    defer t.join();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/0", .{port});
    const start = std.Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, fetchWithin(arena.allocator(), io, &client, url, null, 300));
    const took = start.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(took < 1400);
}

test "only plain relative names are deleted" {
    for ([_][]const u8{ "D2Debug.txt", "support/x.txt", "Diablo II.lnk" }) |p| try std.testing.expect(plainRelative(p));
    for ([_][]const u8{ "", "/x", "D2Debug*.txt", "$(ProgramMenu)/x.lnk", "C:/x", "../x", "a//b", "a/./b", "a?b" }) |p| try std.testing.expect(!plainRelative(p));
}

/// Create every directory on the way to `path`, ignoring the ones already there.
pub fn mkdirs(io: std.Io, path: []const u8) !void {
    // A Windows absolute path starts with a drive or a share, not with "/": it goes to the cwd's
    // createDirPath whole, which resolves it without the cwd.
    if (@import("builtin").os.tag == .windows) return Dir.cwd().createDirPath(io, path);
    if (std.fs.path.isAbsolute(path)) {
        var root = try Dir.openDirAbsolute(io, "/", .{});
        defer root.close(io);
        try root.createDirPath(io, path[1..]);
    } else {
        try Dir.cwd().createDirPath(io, path);
    }
}

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try openFile(io, path, .read_only);
    defer f.close(io);
    const len = try f.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    _ = try f.readPositionalAll(io, buf, 0);
    return buf;
}

fn writeWhole(io: std.Io, path: []const u8, data: []const u8) !void {
    const f = try createFile(io, path);
    defer f.close(io);
    try f.writePositionalAll(io, data, 0);
    try f.setLength(io, data.len);
}

fn fileExists(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buf: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    const f = openFile(io, full, .read_only) catch return false;
    f.close(io);
    return true;
}

// ── http ───────────────────────────────────────────────────────────────────────────────────────

/// The status of the last failed fetch, so a piece failure can say 403 rather than "HttpStatus".
pub threadlocal var last_status: u16 = 0;

/// GET a URL whole. `cookie` is the CDN access token, sent on every piece request.
pub fn fetchUrl(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8, cookie: ?[]const u8) ![]u8 {
    return fetchUrlWatched(gpa, client, url, cookie, null);
}

/// `fetchUrl`, with the connection handed to `watch` once it is open, so the watchdog can shut it
/// down when the attempt runs past its deadline.
fn fetchUrlWatched(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8, cookie: ?[]const u8, watch: ?*Watch) ![]u8 {
    // `Pragma: no-cache` is not the program's doing: the client opens every request with
    // INTERNET_FLAG_RELOAD, and that is what WinInet puts on the wire for it.
    const with_cookie = [_]std.http.Header{
        .{ .name = "Pragma", .value = "no-cache" },
        .{ .name = "Cookie", .value = cookie orelse "" },
    };
    // Not `client.fetch`: when a body read fails for a reason of the socket's own (a cancelled read,
    // a reset), fetch unwraps an HTTP-level error that was never set and panics. The request is
    // driven here instead, and the socket's error is returned as it is.
    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = @enumFromInt(3),
        .headers = .{ .user_agent = .{ .override = legacy.user_agent } },
        .extra_headers = if (cookie != null) &with_cookie else &.{
            .{ .name = "Pragma", .value = "no-cache" },
        },
    });
    defer req.deinit();
    if (watch) |w| if (req.connection) |c| w.attach(c.stream_reader.stream);
    defer if (watch) |w| w.detach();
    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var res = try req.receiveHead(&redirect_buffer);
    if (res.head.status != .ok and res.head.status != .partial_content) {
        last_status = @intFromEnum(res.head.status);
        return error.HttpStatus;
    }
    // The CDN compresses when asked, and the client asks by default; undone here as fetch does.
    const decompress_buffer: []u8 = switch (res.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer gpa.free(decompress_buffer);

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    _ = res.readerDecompressing(&transfer, &decompress, decompress_buffer).streamRemaining(&body.writer) catch |err| switch (err) {
        error.ReadFailed => {
            if (res.bodyErr()) |e| return e;
            if (req.connection) |c| if (c.stream_reader.err) |e| return e;
            return error.ReadFailed;
        },
        error.WriteFailed => return error.OutOfMemory,
    };
    return body.toOwnedSlice();
}

/// A path on disk if there is one there, otherwise a product code to fetch from Blizzard.
pub fn resolveStub(
    gpa: std.mem.Allocator,
    io: std.Io,
    client: *std.http.Client,
    arg: []const u8,
    locale: []const u8,
    os_: []const u8,
    rep: ?*Reporter,
) ![]u8 {
    if (readFile(gpa, io, arg)) |bytes| return bytes else |_| {}

    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    for (arg) |c| try code.append(gpa, std.ascii.toUpper(c));
    const url = try std.fmt.allocPrint(gpa, "{s}?product={s}&locale={s}&os={s}", .{
        getlegacy, code.items, locale, os_,
    });
    defer gpa.free(url);
    const body = fetchUrl(gpa, client, url, null) catch {
        if (rep) |r| r.say(.resolving, "no file '{s}', and fetching product {s} failed\n", .{ arg, code.items });
        return error.NoStub;
    };
    // The endpoint answers 200 with nothing when it is rate-limiting, so size is the real check.
    if (body.len < 1024) {
        gpa.free(body);
        if (rep) |r| r.say(.resolving, "product {s} ({s}, {s}) returned nothing — unknown product, or you are being rate-limited\n", .{ code.items, locale, os_ });
        return error.NoStub;
    }
    return body;
}

// ── fetching ───────────────────────────────────────────────────────────────────────────────────

/// Preallocate every file of the payload at full length under `dest`, so a piece can be written
/// wherever it lands without caring whether the bytes around it have arrived yet.
pub fn preallocate(gpa: std.mem.Allocator, io: std.Io, meta: legacy.Metainfo, dest: []const u8) !void {
    try mkdirs(io, dest);
    for (meta.files) |f| {
        const full = try zpath(gpa, &.{ dest, f.path });
        defer gpa.free(full);
        if (std.mem.lastIndexOfScalar(u8, full, '/')) |at| try mkdirs(io, full[0..at]);
        const fh = try createFile(io, full);
        defer fh.close(io);
        try fh.setLength(io, f.length);
    }
}

/// A piece rarely lands in one file — it routinely straddles the end of one and the start of
/// the next — so writing one means walking its spans.
pub fn writePiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, io: std.Io, dest: []const u8, index: usize, data: []const u8) !void {
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

pub fn readPiece(meta: legacy.Metainfo, gpa: std.mem.Allocator, io: std.Io, dest: []const u8, index: usize, buf: []u8) ![]u8 {
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

pub const FetchOptions = struct {
    first: usize = 0,
    /// Inclusive; null = the last piece.
    last: ?usize = null,
    retries: usize = 3,
    jobs: usize = 4,
    sequential: bool = false,
    /// The CDN access token sent with every piece request.
    cookie: ?[]const u8 = null,
    control: ?*Control = null,
    /// How the destination is named in the closing message.
    label: []const u8 = "",
    /// How long one piece's request may take before it is abandoned and tried again.
    piece_timeout_ms: u64 = piece_timeout_ms,
};

pub const FetchResult = struct {
    /// Pieces finished, including the ones already on disk.
    done: usize,
    /// Of those, the ones already on disk.
    resumed: usize,
    failed: usize,
};

/// Fetch, verify and write every piece of `meta`'s payload in the chosen range into `dest`, which
/// `preallocate` has already laid out. Pieces already there and matching their hash are kept.
/// Fails only when nothing at all succeeded, or on cancel; a partial result says how many failed.
pub fn fetchPayload(gpa: std.mem.Allocator, io: std.Io, meta: legacy.Metainfo, dest: []const u8, opts: FetchOptions, rep: *Reporter) !FetchResult {
    const last = opts.last orelse meta.pieceCount() - 1;

    // Pieces are fetched in a random order rather than 0,1,2,... — that is what the CDN
    // expects to see, and it spreads a resumed download instead of replaying one region.
    const order = try gpa.alloc(usize, last - opts.first + 1);
    defer gpa.free(order);
    for (order, 0..) |*o, k| o.* = opts.first + k;
    if (!opts.sequential) {
        // Seeded from the clock, the same way the client seeds the rand() behind its shuffle,
        // so consecutive runs do not repeat an order.
        const now = std.Io.Timestamp.now(io, .real);
        var prng = std.Random.DefaultPrng.init(@truncate(@as(u96, @bitCast(now.nanoseconds))));
        prng.random().shuffle(usize, order);
    }

    var total: u64 = 0;
    for (opts.first..last + 1) |p| total += meta.pieceSize(p);

    // Several pieces at once. The real client does the same, governed by its maxpending and
    // maxsimultaneous settings; neither it nor this caps the download rate itself.
    var shared: Fetch = .{
        .meta = meta,
        .order = order,
        .from = opts.first,
        .last = last,
        .dest = dest,
        .retries = opts.retries,
        .cookie = opts.cookie,
        .control = opts.control,
        .rep = rep,
        .total = total,
        .timeout_ms = opts.piece_timeout_ms,
    };
    {
        rep.acquire();
        defer rep.release();
        rep.counters[@intFromEnum(Stage.downloading)] = .{ 0, total };
        rep.emitLocked(.{ .stage = .downloading, .done = 0, .total = total, .pieces = .{ .first = opts.first, .count = order.len } });
    }

    {
        const workers = try gpa.alloc(std.Thread, @max(1, opts.jobs));
        defer gpa.free(workers);
        var spawned: usize = 0;
        for (workers) |*t| {
            t.* = std.Thread.spawn(.{}, Fetch.work, .{&shared}) catch break;
            spawned += 1;
        }
        // If no thread could start, do the work here rather than silently finishing early.
        if (spawned == 0) Fetch.work(&shared) else for (workers[0..spawned]) |t| t.join();
    }

    if (isCancelled(opts.control)) return error.Cancelled;

    const res: FetchResult = .{ .done = shared.done, .resumed = shared.resumed, .failed = shared.failed };
    if (shared.gave_up) {
        rep.say(.downloading, "\n{d} pieces failed and none succeeded.\n" ++
            "A 403 here usually means the stub's access token has expired; fetch a fresh\n" ++
            "stub by asking for the product code, or pass --cookie. See the README.\n", .{res.failed});
        return error.AllPiecesFailed;
    }
    if (res.resumed != 0)
        rep.say(.downloading, "\n{d} pieces written, {d} already had, {d} failed -> {s}/{s}\n", .{ res.done - res.resumed, res.resumed, res.failed, opts.label, meta.name })
    else
        rep.say(.downloading, "\n{d} pieces written, {d} failed -> {s}/{s}\n", .{ res.done, res.failed, opts.label, meta.name });
    return res;
}

/// How long one piece (256 KiB) may take before its request is abandoned and tried again on a fresh connection.
/// A CDN connection can stay open and send nothing; without a limit the whole download waits on it forever.
pub const piece_timeout_ms: u64 = 60_000;

/// A deadline for one request at a time, kept by a thread of its own (watch.zig).
pub const Watch = watch_mod.Watch;

/// One request under `watch`'s deadline: error.Timeout once it runs past `timeout_ms`. A request
/// still connecting when the deadline passes ends by the system's own connect and lookup timeouts.
fn fetchAttempt(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, url: []const u8, cookie: ?[]const u8, watch: *Watch, timeout_ms: u64) ![]u8 {
    watch.begin(io, timeout_ms);
    const got = fetchUrlWatched(gpa, client, url, cookie, watch);
    if (watch.end()) {
        if (got) |b| gpa.free(b) else |_| {}
        return error.Timeout;
    }
    return got;
}

/// `fetchUrl`, abandoned when it takes longer than `timeout_ms`: error.Timeout. `client` must use an
/// `Io` that runs nothing on other threads (`Io.Threaded` with no async or concurrent limit), see
/// `Watch`.
pub fn fetchWithin(gpa: std.mem.Allocator, io: std.Io, client: *std.http.Client, url: []const u8, cookie: ?[]const u8, timeout_ms: u64) ![]u8 {
    var watch: Watch = .{};
    const t = try watch.start();
    defer watch.stop(t);
    return fetchAttempt(gpa, io, client, url, cookie, &watch, timeout_ms);
}

/// The `Io` a fetch worker uses: everything on the calling thread (see `Watch`).
pub fn workerIo(threaded: *std.Io.Threaded) void {
    watch_mod.singleThreaded(threaded, std.heap.page_allocator);
}

/// The shared state a set of fetch workers pulls from. The piece cursor is a fetch-and-add, so a
/// worker only ever needs the next index and never waits on the others; the counters move under
/// the reporter's lock, so the events they produce are in order.
const Fetch = struct {
    meta: legacy.Metainfo,
    order: []const usize,
    from: usize,
    last: usize,
    dest: []const u8,
    retries: usize,
    cookie: ?[]const u8,
    control: ?*Control,
    rep: *Reporter,
    total: u64,
    timeout_ms: u64,

    cursor: usize = 0,
    done: usize = 0,
    failed: usize = 0,
    resumed: usize = 0,
    bytes: u64 = 0,
    gave_up: bool = false,

    fn take(f: *Fetch, io: std.Io) ?usize {
        checkpoint(io, f.control) catch return null;
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
        var threaded: std.Io.Threaded = undefined;
        workerIo(&threaded);
        defer threaded.deinit();
        const io = threaded.io();

        var watch: Watch = .{};
        const watchdog = watch.start() catch null;
        defer if (watchdog) |t| watch.stop(t);

        var client: std.http.Client = .{ .allocator = stable, .io = io };
        defer client.deinit();

        var scratch_state = std.heap.ArenaAllocator.init(stable);
        defer scratch_state.deinit();

        while (f.take(io)) |p| {
            if (@atomicLoad(bool, &f.gave_up, .monotonic)) return;
            _ = scratch_state.reset(.retain_capacity);
            const scratch = scratch_state.allocator();
            const want = f.meta.pieceSize(p);

            // Anything already on disk and matching its hash is left alone, so an interrupted
            // fetch resumes instead of downloading what it already has.
            if (scratch.alloc(u8, want)) |buf| {
                if (readPiece(f.meta, scratch, io, f.dest, p, buf)) |have| {
                    if (f.meta.verify(p, have)) |_| {
                        f.finish(p, true, true, "");
                        continue;
                    } else |_| {}
                } else |_| {}
            } else |_| {}

            var attempt: usize = 0;
            var last_err: []const u8 = "unknown";
            const ok = while (attempt <= f.retries) : (attempt += 1) {
                if (isCancelled(f.control)) return;
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
                // Without a watchdog there is no deadline, but the piece is still fetched.
                const body = (if (watchdog != null)
                    fetchAttempt(scratch, io, &client, url, f.cookie, &watch, f.timeout_ms)
                else
                    fetchUrl(scratch, &client, url, f.cookie)) catch |e| {
                    last_err = if (e == error.HttpStatus)
                        std.fmt.allocPrint(scratch, "HTTP {d}", .{last_status}) catch "HttpStatus"
                    else
                        @errorName(e);
                    if (e == error.Timeout) {
                        // A connection that went quiet: drop every pooled connection, so the retry dials anew.
                        client.deinit();
                        client = .{ .allocator = stable, .io = io };
                        if (attempt < f.retries)
                            f.rep.say(.downloading, "\n  piece {d}: no answer for {d} s, trying again on a new connection\n", .{ p, f.timeout_ms / 1000 });
                    }
                    // A little longer between tries each time.
                    std.Io.sleep(io, .fromMilliseconds(@intCast(250 * (attempt + 1))), .awake) catch {};
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

            if (ok) {
                f.finish(p, true, false, "");
                continue;
            }
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "\n  piece {d}: {s} after {d} tries\n", .{ p, last_err, f.retries + 1 }) catch "";
            f.finish(p, false, false, msg);
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

    fn finish(f: *Fetch, piece: usize, ok: bool, resumed: bool, message: []const u8) void {
        f.rep.acquire();
        defer f.rep.release();
        if (ok) {
            _ = @atomicRmw(usize, &f.done, .Add, 1, .monotonic);
            if (resumed) _ = @atomicRmw(usize, &f.resumed, .Add, 1, .monotonic);
            f.bytes += f.meta.pieceSize(piece);
        } else {
            _ = @atomicRmw(usize, &f.failed, .Add, 1, .monotonic);
        }
        f.rep.counters[@intFromEnum(Stage.downloading)] = .{ f.bytes, f.total };
        var label: [24]u8 = undefined;
        f.rep.emitLocked(.{
            .stage = .downloading,
            .done = f.bytes,
            .total = f.total,
            .file = std.fmt.bufPrint(&label, "piece {d}", .{piece}) catch "",
            .message = message,
            .pieces = .{
                .index = piece,
                .ok = ok,
                .resumed = resumed,
                .first = f.from,
                .count = f.order.len,
                .done = @atomicLoad(usize, &f.done, .monotonic),
                .failed = @atomicLoad(usize, &f.failed, .monotonic),
            },
        });
    }
};

// ── the whole pipeline ─────────────────────────────────────────────────────────────────────────

/// Fetch a product's payload (and its base game's, for an expansion), build the game directory
/// from it, and patch it to `opts.version`.
///
/// Holds each payload's Installer Tome archives in memory while installing from them, plus one
/// installed archive at a time while patching; see the README for sizes. Spawns `opts.jobs`
/// threads while downloading, each with its own `std.Io.Threaded` and HTTP client; `io` itself is
/// used only from the calling thread.
pub fn install(gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rep: Reporter = .init(opts.progress);
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    try checkpoint(io, opts.control);
    const dir_path = opts.cache_dir orelse try defaultCacheDir(arena, io);

    // An expansion installs over its base game, so asking to install one means installing both,
    // base first.
    const code = try arena.dupe(u8, opts.product);
    if (code.len <= 8) for (code) |*c| {
        c.* = std.ascii.toUpper(c.*);
    };
    const targets: []const []const u8 =
        if (!opts.no_base and std.mem.eql(u8, code, "D2XP")) &.{ "D2DV", "D2XP" } else if (!opts.no_base and std.mem.eql(u8, code, "W3XP")) &.{ "WAR3", "W3XP" } else &.{opts.product};

    // The requested product's stub, resolved once and reused by its own pass.
    var requested: ?[]u8 = null;

    // Both halves land in one game directory, named for what was actually asked for.
    const game_root = if (opts.game_dir.len != 0) opts.game_dir else blk: {
        rep.begin(code);
        rep.set(.resolving, 0, 0, opts.product);
        requested = try resolveStub(arena, io, &client, opts.product, opts.locale, opts.os, &rep);
        const m = try legacy.fromStub(arena, requested.?);
        break :blk try std.fmt.allocPrint(arena, "{s}/{s}-game", .{ dir_path, m.name });
    };

    for (targets, 0..) |target, pass| {
        const label = if (target.len <= 8) try std.ascii.allocUpperString(arena, target) else target;
        rep.begin(label);
        rep.set(.resolving, 0, 0, target);
        if (targets.len > 1) rep.say(.resolving, "\n=== {s} ===\n", .{target});

        const is_requested = targets.len == 1 or std.mem.eql(u8, label, code);
        const stub = if (is_requested and requested != null)
            requested.?
        else
            try resolveStub(arena, io, &client, target, opts.locale, opts.os, &rep);
        var meta = try legacy.fromStub(arena, stub);

        // The pieces are numbered files under one base, so any host laid out the same way serves
        // them. This replaces the whole server set the torrent named, through the same expansion
        // the client uses, so 'http://m[1-4]/p' names four mirrors.
        if (opts.base_url) |b| {
            var mirrors: std.ArrayList(legacy.Server) = .empty;
            try legacy.expandServerUrls(arena, std.mem.trimEnd(u8, b, "/"), &mirrors);
            meta.servers = try mirrors.toOwnedSlice(arena);
            meta.direct_download = b;
        }
        // Without a token every piece request comes back 403.
        const cookie = opts.cookie orelse meta.token;
        rep.set(.resolving, 1, 1, meta.name);

        // The payload's own top-level directory, so an assembled tree matches what the stub
        // expects to launch.
        const dest = try zpath(arena, &.{ dir_path, meta.name });
        try preallocate(arena, io, meta, dest);

        const got = try fetchPayload(arena, io, meta, dest, .{
            .first = opts.first_piece,
            .last = opts.last_piece,
            .retries = opts.retries,
            .jobs = opts.jobs,
            .sequential = opts.sequential,
            .cookie = cookie,
            .control = opts.control,
            .label = dir_path,
        }, &rep);
        if (got.failed != 0) return error.Incomplete;

        try installPayload(arena, gpa, io, &rep, &client, opts, dest, game_root, if (pass + 1 == targets.len) opts.version else null);
    }
    rep.set(.done, 1, 1, game_root);
}

/// The archives an install lays down, in the order the game searches them. `patch_d2.mpq` is not
/// among them: the patch rebuilds that one outright.
const installed_archives = [_][]const u8{
    "d2exp.mpq",  "d2xtalk.mpq", "d2xmusic.mpq", "d2xvideo.mpq", "d2data.mpq",
    "d2char.mpq", "d2sfx.mpq",   "d2music.mpq",  "d2speech.mpq", "d2video.mpq",
};

/// Build the game directory from a payload that has just been fetched.
///
/// The payload's archives hold both the files and the script saying where they go. Everything the
/// script asks for that has meaning off Windows is done; the registry keys, shortcuts and DirectX
/// bundle it also asks for are counted and reported instead.
///
/// `gpa` holds what lives for the whole install; `big` takes the archive-sized buffers that are
/// freed as soon as they have been written, so that they do not pile up.
fn installPayload(
    gpa: std.mem.Allocator,
    big: std.mem.Allocator,
    io: std.Io,
    rep: *Reporter,
    client: *std.http.Client,
    opts: Options,
    payload: []const u8,
    game: []const u8,
    version: ?[]const u8,
) !void {
    try checkpoint(io, opts.control);

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
        rep.say(.installing, "no Installer Tome in {s}\n", .{payload});
        return error.NoTome;
    }

    const manifest = set.read(gpa, script.manifest_path) catch {
        rep.say(.installing, "the payload carries no install script\n", .{});
        return error.NoManifest;
    };
    // An expansion installs over the base game, and deletes from where it already sits.
    const original = try std.fmt.allocPrint(gpa, "{s}/", .{game});
    const plan = try script.parse(gpa, manifest, .{
        .platform = switch (opts.platform) {
            .win32 => .win32,
            .macos => .macos,
        },
        .language = opts.language,
        .symbols = &.{.{ .name = "OriginalInstallPath", .value = original }},
    });

    // One step per operation, and one per archive rewritten at the end.
    var containers: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (plan.ops) |op| switch (op) {
        .add_to_archive => |a| if (a.file.from != null) try containers.put(gpa, a.container, {}),
        .encrypt => |e| if (e.container) |c| if (opts.secrets.textFor(e.object, e.product_id) != null) try containers.put(gpa, c, {}),
        else => {},
    };
    const steps: u64 = plan.ops.len + containers.count();
    var step: u64 = 0;
    rep.set(.installing, 0, steps, "");

    rep.say(.installing, "\ninstalling {d} operations from {d} archive(s) -> {s}\n", .{ plan.ops.len, found, game });
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

    for (plan.ops) |op| {
        try checkpoint(io, opts.control);
        defer {
            step += 1;
            rep.set(.installing, step, steps, switch (op) {
                .extract => |f| f.to,
                .add_to_archive => |a| a.file.to,
                .encrypt => |e| e.object,
                .delete => |path| path,
                else => "",
            });
        }
        switch (op) {
            .extract => |f| {
                const from = f.from orelse continue;
                const data = set.read(big, from) catch continue;
                defer big.free(data);
                const rel = try gpa.dupe(u8, f.to);
                defer gpa.free(rel);
                for (rel) |*c| if (c.* == '\\') {
                    c.* = '/';
                };
                // Only a plain file inside the game folder: the script also names wildcards, variables
                // and places outside it, and Windows treats such a name as a caller's bug, not an error.
                if (!plainRelative(rel)) {
                    rep.say(.installing, "  not deleting {s} (not a plain file in the game folder)\n", .{rel});
                    continue;
                }
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
                const text = opts.secrets.textFor(e.object, e.product_id) orelse {
                    elsewhere += 1;
                    continue;
                };
                // The wrapping password is fixed for every install on earth, so nothing about this
                // depends on the machine it runs on: the same key produces a blob any copy reads.
                const pw = keystore.blockKey();
                const blob = try gpa.alloc(u8, keystore.wrappedLen(text.len));
                keystore.encrypt(blob, text, &pw);
                try bind(gpa, &bound, container, .{ .name = e.into, .data = blob });
                rep.say(.installing, "  storing {s} in {s}\n", .{ e.object, container });
                hidden += 1;
            },
            .delete => |path| {
                const rel = try gpa.dupe(u8, path);
                defer gpa.free(rel);
                for (rel) |*c| if (c.* == '\\') {
                    c.* = '/';
                };
                // Only a plain file inside the game folder: the script also names wildcards, variables
                // and places outside it, and Windows treats such a name as a caller's bug, not an error.
                if (!plainRelative(rel)) {
                    rep.say(.installing, "  not deleting {s} (not a plain file in the game folder)\n", .{rel});
                    continue;
                }
                const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, rel });
                defer gpa.free(full);
                Dir.cwd().deleteFile(io, full) catch {};
                rep.say(.installing, "  replacing {s}\n", .{rel});
            },
            else => elsewhere += 1,
        }
    }

    // One rewrite per archive, carrying every member bound for it.
    for (bound.keys(), bound.values()) |container, list| {
        try checkpoint(io, opts.control);
        defer {
            step += 1;
            rep.set(.installing, step, steps, container);
        }
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, container });
        defer gpa.free(path);
        const before = readFile(big, io, path) catch continue;
        defer big.free(before);
        const grown = mpq.append(big, before, list.items) catch continue;
        defer big.free(grown);
        try writeWhole(io, path, grown);
        added += list.items.len;
    }
    rep.set(.installing, steps, steps, "");

    rep.say(.installing, "{d} files, {d} members added to installed archives, {d} steps only Windows can do\n", .{ wrote, added, elsewhere });
    if (opts.secrets.any() and hidden == 0)
        rep.say(.installing, "!! nothing was stored: this script asks for no value the given options supply\n", .{});

    const last_stage: Stage = if (version != null) .patching else .installing;
    if (version) |v| try patchTo(gpa, big, io, rep, client, opts.control, &set, game, v, found > 0 and set.has("PC-100x\\Game.exe"), opts.patch_source);
    rep.say(last_stage, "the game is in {s}\n", .{game});
    if (version) |v| if (copyProtected(v)) rep.say(.patching,
        \\
        \\!! {s} will not start on current Windows, and nothing is missing from the install.
        \\   Its Game.exe is Blizzard's, wrapped in SafeDisc: the copy protection on every Diablo II
        \\   client before 1.12. It wants the play disc, read through a driver Windows 10 and later no
        \\   longer ship; without them it exits within seconds, with no window and exit code 2. 1.12a
        \\   and later carry no copy protection.
        \\
    , .{v});
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
    big: std.mem.Allocator,
    io: std.Io,
    rep: *Reporter,
    client: *std.http.Client,
    control: ?*Control,
    set: *const mpq.Set,
    game: []const u8,
    version: []const u8,
    expansion: bool,
    source: []const u8,
) !void {
    try checkpoint(io, control);
    // Version strings are written 1.09b but the archives are named 109b.
    var tidy: std.ArrayList(u8) = .empty;
    for (version) |c| if (c != '.') try tidy.append(gpa, c);
    const url = try std.fmt.allocPrint(gpa, "{s}/{s}Patch_{s}.exe", .{
        source, if (expansion) "LOD" else "D2", tidy.items,
    });
    rep.set(.patching, 0, 0, url);
    rep.say(.patching, "\npatching to {s}\n  {s}\n", .{ version, url });

    const exe = fetchUrl(gpa, client, url, null) catch |e| {
        rep.say(.patching, "  no patch archive for {s} ({t})\n", .{ version, e });
        return error.NoSuchVersion;
    };
    try checkpoint(io, control);
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
    const entries = if (disk_map) |text| try ptc.parseMap(gpa, text) else &.{};

    // One step per file on disk, one for patch_d2.mpq, one for the archive fix-up.
    const steps: u64 = entries.len + 2;
    var step: u64 = 0;
    rep.set(.patching, 0, steps, "");

    var wrote: usize = 0;
    var unchanged: usize = 0;
    for (entries) |m| {
        try checkpoint(io, control);
        const name = m.basename();
        defer {
            step += 1;
            rep.set(.patching, step, steps, name);
        }
        // A file the patch does not carry is one it does not change; the installed copy stays.
        const rec_bytes = patch.read(gpa, m.member) catch {
            unchanged += 1;
            continue;
        };
        const rec = ptc.Record.parse(rec_bytes) catch continue;

        // The source is the original build for this product, not what is on disk.
        const src = base.get(name) orelse blk: {
            const member = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, name });
            const b = set.read(gpa, member) catch &[_]u8{};
            try base.put(gpa, name, b);
            break :blk b;
        };
        const out = ptc.apply(gpa, rec, src) catch |e| {
            rep.say(.patching, "  refused {s}: {t}\n", .{ name, e });
            continue;
        };
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, name });
        try writeWhole(io, full, out);
        wrote += 1;
    }

    // patch_d2.mpq is rebuilt from nothing, exactly as the script asks.
    try checkpoint(io, control);
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
            try checkpoint(io, control);
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, archive_name });
            defer gpa.free(path);
            const bytes = readFile(big, io, path) catch continue;
            defer big.free(bytes);
            var have = mpq.Archive.open(big, bytes) catch continue;
            defer have.deinit(big);
            for (want.items) |*w| {
                if (w.data != null) continue;
                const src = have.read(big, w.name) catch continue;
                defer big.free(src);
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
            const built = try mpq.append(big, empty, members.items);
            defer big.free(built);
            const full = try std.fmt.allocPrint(gpa, "{s}/patch_d2.mpq", .{game});
            try writeWhole(io, full, built);
            rebuilt = members.items.len - 1; // the listfile is ours, not one of the patch's members
        }
    } else |_| {}
    step += 1;
    rep.set(.patching, step, steps, "patch_d2.mpq");

    rep.say(.patching, "  {d} files patched, {d} left as installed, patch_d2.mpq rebuilt with {d} members\n", .{ wrote, unchanged, rebuilt });
    if (short != 0) rep.say(.patching, "  {d} members of patch_d2.mpq could not be rebuilt\n", .{short});

    // Only a version that ships its own Storm.dll reads the archives through it; 1.14 links its
    // archive code into Game.exe and reads everything the payload carries.
    if (fileExists(io, game, "Storm.dll")) {
        for (installed_archives) |archive_name| {
            try checkpoint(io, control);
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ game, archive_name });
            defer gpa.free(path);
            const bytes = readFile(big, io, path) catch continue;
            defer big.free(bytes);
            if (!try unhookModernAttributes(big, bytes)) continue;
            try writeWhole(io, path, bytes);
            rep.say(.patching, "  {s}: unlisted its (attributes), which this version's Storm.dll cannot read\n", .{archive_name});
        }
    }
    rep.set(.patching, steps, steps, "");
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

/// Whether the Windows `Game.exe` of a version is wrapped in SafeDisc. Every client from 1.00 to
/// 1.11b is (sections `.cms_t`/`.cms_d`, later randomly named ones); 1.12a dropped the disc check
/// and with it the wrapper. Versions are written `1.09b`, so the two digits after `1.` decide.
pub fn copyProtected(version: []const u8) bool {
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
