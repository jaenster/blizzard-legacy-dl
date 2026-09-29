//! What Blizzard's getLegacy endpoint (and any other request the installer makes) answered, and what that
//! answer means. The endpoint fails in ways that look alike from the outside: it rate-limits by answering
//! 200 with nothing, a network in between can hand back a sign-in or block page, and a region Blizzard
//! does not serve gets a refusal. Each gets its own verdict, so the caller can tell the player which it was
//! and the log can show the evidence.
const std = @import("std");

pub const Verdict = enum {
    /// A response that can be a downloader stub.
    ok,
    /// 401, 403 or 451: Blizzard (or something in front of it) refused this network or region.
    blocked,
    /// 429.
    rate_limited,
    /// 200 with nothing or next to nothing: how the endpoint rate-limits, and what an unknown product gets.
    empty,
    /// An HTML page where the downloader should be: a proxy, a captive portal, a block page.
    web_page,
    /// 404 or 410.
    not_found,
    /// 5xx.
    server_error,
    /// More redirects than the client follows.
    redirect_loop,
    /// Some other status.
    unexpected_status,
    /// Big enough and not a page, but no torrent in it: cut off, or rewritten on the way.
    bad_stub,

    /// Worth asking again after a pause.
    pub fn transient(v: Verdict) bool {
        return switch (v) {
            .rate_limited, .empty, .server_error, .bad_stub => true,
            else => false,
        };
    }

    pub fn label(v: Verdict) []const u8 {
        return switch (v) {
            .ok => "ok",
            .blocked => "refused (blocked)",
            .rate_limited => "rate-limited (429)",
            .empty => "empty answer",
            .web_page => "a web page instead of the downloader",
            .not_found => "not found",
            .server_error => "server error",
            .redirect_loop => "redirect loop",
            .unexpected_status => "unexpected status",
            .bad_stub => "not a downloader",
        };
    }
};

/// The smallest a real stub is; the endpoint's 200-with-nothing is far below it.
pub const min_stub_bytes = 1024;

/// Whether `body` opens like markup (after any byte-order mark and whitespace).
pub fn looksLikeHtml(body: []const u8) bool {
    var s = body;
    if (std.mem.startsWith(u8, s, "\xEF\xBB\xBF")) s = s[3..];
    s = std.mem.trimStart(u8, s, " \t\r\n");
    return s.len > 0 and s[0] == '<';
}

/// The verdict on a response: `head` is the start of its body (as much as was read), `body_len` its
/// whole length when known, else `head.len`.
pub fn classify(status: u16, content_type: []const u8, head: []const u8, body_len: usize) Verdict {
    switch (status) {
        200, 206 => {
            if (body_len == 0) return .empty;
            if (std.ascii.indexOfIgnoreCase(content_type, "html") != null or looksLikeHtml(head)) return .web_page;
            if (body_len < min_stub_bytes) return .empty;
            return .ok;
        },
        401, 403, 451 => return .blocked,
        429 => return .rate_limited,
        404, 410 => return .not_found,
        300...399 => return .redirect_loop,
        500...599 => return .server_error,
        else => return .unexpected_status,
    }
}

/// Seconds to wait before attempt `n` (0 is the first, immediate).
pub fn backoffSeconds(n: usize) u64 {
    return switch (n) {
        0 => 0,
        1 => 3,
        2 => 8,
        else => 20,
    };
}

pub const attempts = 4;

/// The evidence of the last response, kept per thread: what a failure line in the log is built from.
pub const Diag = struct {
    pub const url_cap = 160;
    pub const head_cap = 40;

    status: u16 = 0,
    ct: [64]u8 = undefined,
    ct_len: u8 = 0,
    url: [url_cap]u8 = undefined,
    url_len: u8 = 0,
    head: [head_cap]u8 = undefined,
    head_len: u8 = 0,
    body_len: usize = 0,

    pub fn reset(d: *Diag) void {
        d.* = .{};
    }

    /// Note a response's status and headers; `final_url` is where redirects ended, kept without its query.
    pub fn setResponse(d: *Diag, status: u16, content_type: ?[]const u8, final_url: []const u8) void {
        d.status = status;
        const ct = content_type orelse "";
        d.ct_len = @intCast(@min(ct.len, d.ct.len));
        @memcpy(d.ct[0..d.ct_len], ct[0..d.ct_len]);
        const bare = final_url[0 .. std.mem.indexOfAny(u8, final_url, "?#") orelse final_url.len];
        d.url_len = @intCast(@min(bare.len, d.url.len));
        @memcpy(d.url[0..d.url_len], bare[0..d.url_len]);
        d.head_len = 0;
        d.body_len = 0;
    }

    pub fn contentType(d: *const Diag) []const u8 {
        return d.ct[0..d.ct_len];
    }

    pub fn headBytes(d: *const Diag) []const u8 {
        return d.head[0..d.head_len];
    }

    pub fn setBody(d: *Diag, head: []const u8, body_len: usize) void {
        d.head_len = @intCast(@min(head.len, d.head.len));
        @memcpy(d.head[0..d.head_len], head[0..d.head_len]);
        d.body_len = body_len;
    }

    /// One line: status, content type, size, final URL and the first bytes, printable.
    pub fn describe(d: *const Diag, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        w.print("HTTP {d}, content-type '{s}', {d} bytes, from {s}, starts '", .{ d.status, d.ct[0..d.ct_len], d.body_len, d.url[0..d.url_len] }) catch return w.buffered();
        for (d.head[0..d.head_len]) |c| w.writeByte(if (c >= 0x20 and c < 0x7f and c != '\'') c else '.') catch break;
        w.writeAll("'") catch {};
        return w.buffered();
    }
};

const testing = std.testing;

// Recorded shapes of what getLegacy and its neighbours answered.
const stub_head = "MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff";
const block_page = "<!DOCTYPE html><html><head><title>Access Denied</title></head><body>Sorry</body></html>";

test "the 200 stub is ok" {
    try testing.expectEqual(Verdict.ok, classify(200, "application/octet-stream", stub_head, 2_700_000));
    try testing.expectEqual(Verdict.ok, classify(200, "", stub_head, 2_700_000));
}

test "403 with a block page is a refusal" {
    try testing.expectEqual(Verdict.blocked, classify(403, "text/html", block_page, block_page.len));
    try testing.expectEqual(Verdict.blocked, classify(451, "text/html", "", 0));
    try testing.expect(!Verdict.blocked.transient());
}

test "429 is rate limiting, and worth waiting out" {
    try testing.expectEqual(Verdict.rate_limited, classify(429, "text/plain", "slow down", 9));
    try testing.expect(Verdict.rate_limited.transient());
}

test "200 with nothing is the endpoint rate-limiting" {
    try testing.expectEqual(Verdict.empty, classify(200, "application/octet-stream", "", 0));
    try testing.expectEqual(Verdict.empty, classify(200, "text/plain", "no", 2));
    try testing.expect(Verdict.empty.transient());
}

test "200 with a page is a proxy or a portal, not retried" {
    try testing.expectEqual(Verdict.web_page, classify(200, "text/html; charset=utf-8", block_page, 40_000));
    try testing.expectEqual(Verdict.web_page, classify(200, "", "\xEF\xBB\xBF \n<html>", 5000));
    try testing.expect(!Verdict.web_page.transient());
}

test "a redirect that never ends" {
    try testing.expectEqual(Verdict.redirect_loop, classify(302, "", "", 0));
}

test "missing and broken" {
    try testing.expectEqual(Verdict.not_found, classify(404, "", "", 0));
    try testing.expectEqual(Verdict.server_error, classify(503, "text/html", block_page, block_page.len));
    try testing.expectEqual(Verdict.unexpected_status, classify(418, "", "", 0));
}

test "the backoff grows and every wait is finite" {
    try testing.expectEqual(@as(u64, 0), backoffSeconds(0));
    var total: u64 = 0;
    for (0..attempts) |n| total += backoffSeconds(n);
    try testing.expect(total <= 60);
    try testing.expect(backoffSeconds(2) > backoffSeconds(1));
}

test "the log line carries status, type, size, url and the first bytes" {
    var d: Diag = .{};
    d.setResponse(403, "text/html", "https://downloader.battle.net/download/getLegacy?product=D2XP&locale=en-US&os=WIN");
    d.setBody(block_page[0..30], 812);
    var buf: [400]u8 = undefined;
    const s = d.describe(&buf);
    try testing.expectEqualStrings("HTTP 403, content-type 'text/html', 812 bytes, from https://downloader.battle.net/download/getLegacy, starts '<!DOCTYPE html><html><head><ti'", s);
}

test "binary bytes are shown as dots" {
    var d: Diag = .{};
    d.setResponse(200, null, "https://x/y");
    d.setBody(stub_head, 3);
    var buf: [400]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, d.describe(&buf), "starts 'MZ...") != null);
}
