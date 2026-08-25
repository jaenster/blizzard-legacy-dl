# blizzard-legacy-dl

Reads a Blizzard legacy downloader stub and fetches what it points at, without running it.

```
docker run --rm ghcr.io/jaenster/blizzard-legacy-dl info D2DV
docker run --rm -v "$PWD:/data" ghcr.io/jaenster/blizzard-legacy-dl fetch D2DV -o /data
```

Or grab a static binary from the releases page, or build it:

```
zig build
zig-out/bin/blizzard-legacy-dl info  D2DV
zig-out/bin/blizzard-legacy-dl fetch D2DV -o ./out
```

You can pass a product code and it grabs the stub from Blizzard itself. A path works too, if you
already have one:

```
zig-out/bin/blizzard-legacy-dl info Downloader_Diablo2_enUS.exe
zig-out/bin/blizzard-legacy-dl info STAR --locale de-DE --os MAC
zig-out/bin/blizzard-legacy-dl stubs -o ./stubs        # all 85 of them
```

`--locale` defaults to `en-US`, `--os` to `WIN`.

## Where the stubs come from

Blizzard still serves them, no account needed:

```
https://downloader.battle.net/download/getLegacy?product=D2DV&locale=en-US&os=WIN
```

Only five products answer: `D2DV D2XP STAR WAR3 W3XP`. Everything else (`DRTL`, `W2BN`, `DSHR`,
`D2ST`, `W3DM`, `WOW`, `D3`, ...) gives a 400. `os` is `WIN` or `MAC`, nothing else. Locales vary
per product; D2DV has `en-US en-GB de-DE es-ES fr-FR it-IT ko-KR pl-PL zh-TW`.

That works out to 85 stubs, all different files, because the locale is compiled in.

The endpoint rate-limits. Sleep between requests or you get empty replies that look like 404s.

## How the download works

The stub is a BitTorrent client, and its torrent is bencoded inside the executable. On Mac it is
a separate `downloader.torrent` in the app bundle. Either way this tool finds it.

Besides the usual `info` dictionary there are Blizzard's own keys: `announce`, `direct download`,
`launch target`, `mac launch target`, `locale`, `use pieces`.

The trackers are gone. All five regions still have DNS pointing at Blizzard addresses but port
3724 is closed everywhere, and the client tells you so ("The tracker is not responding") while
downloading fine anyway. It falls back to the `direct download` URL, which it treats as just
another peer, URL where the peer id would go.

### Where the piece URLs come from

`direct download` is not one URL, which is easy to miss because none of Blizzard's own stubs
use more than one. Traced through `DirectDownload_ExpandServerUrls` in the binary, the string
splits on `|`, and each URL may carry a bracket group in the host: the body splits on `,`, and
an item of the form `a-b` is the inclusive range. So

```
http://dl[1-3,7]/x   ->   http://dl1/x  http://dl2/x  http://dl3/x  http://dl7/x
```

The rebuilt URL is prefix + N + everything from the first `/`, so host text between `]` and the
path is dropped — the bracket is meant to end the hostname.

Five things can supply a server, and this is the complete list:

|source|range|
|-|-|
|torrent `direct download`, expanded|every piece|
|torrent `server list` `[{begin,end,url}]`|`begin..end`|
|tracker announce reply, `direct.url`, expanded|every piece|
|tracker announce reply, `direct."server list"`|`begin..end`|
|config `directDownloadURL`|overrides the base|

The tracker one matters more than it looks: a live tracker could move the client onto entirely
different CDN hosts without the stub changing. All five are dead ends for these stubs — every
one of the 44 carries a single bracket-free URL and no `server list`, and the trackers stopped
answering around 2016 — but the client accepts all of it, so `--base` does too.

The client keeps whichever server it is on while that server's throughput stays at or above
4000000, then re-picks among those whose range covers the wanted piece.

That HTTP source serves one numbered file per piece:

```
<direct download>/0
<direct download>/1
...
```

Not the payload's files, and not one big file you range-request. This is the whole reason curling
the base URL or any path out of `info.files` gets you nowhere. Every piece is its own object with
its own SHA-1 in `info.pieces`, so they can be pulled in any order and in parallel. It is also why
the real client's progress bar fills in scattered blocks instead of left to right.

The exact request, captured off the wire from `Blizzard Downloader 2.2.0.1285` rather than read
out of the disassembly:

```
GET /applications/Diablo2/1.14B/D2/enUS/0 HTTP/1.1
Host: rogue.blizzard.com.edgesuite.net
User-Agent: Blizzard Web Client
Accept: */*
Connection: Keep-Alive
```

No Referer, no Range, no token or cookie. (Watched through a proxy the last header arrives as
`Proxy-Connection`, which is WinInet's doing, not the program's.) Retries append
`?<random letters>` to miss the CDN cache. `Range:` shows up only when the metainfo sets
`chunk length` bigger than `piece length`, which none of these do.

Before any of that the downloader fetches `http://12.129.222.52/update/Downloader.ini`, a
hardcoded address that no longer answers. Nothing recovers from it — the program simply waits out
the connect timeout, which is most of the pause on startup.

Two details cost me an afternoon, so they are worth writing down. Pieces go through WinInet
(`HttpDirect_RequestPiece` calls `HttpWinInet_SendRequest`), not the socket code in
`Http-get.cpp`. And those two paths send different user agents: the socket one is the tracker's
and says `Blizzard Downloader 2.2`, while pieces come from
`InternetOpenA("Blizzard Web Client", ...)`. Copy the wrong one and nothing works.

## The access token

Every piece request has to carry a signed cookie, and this is the single thing that decides
whether the CDN answers 200 or 403:

```
Cookie: bcac=expires=<unix>~access=/applications/Diablo2/1.14B/D2/enUS/*~md5=<32 hex>
```

That is Akamai token authentication. Without it **every** path under the host returns 403 —
`/` and `/robots.txt` included — so from outside it is indistinguishable from an IP-level block,
which is exactly what it looks like and exactly what I assumed for a while. The `Reference #18`
in Akamai's error page is what a token failure looks like; an unknown hostname gives a different
code (`400`, `Reference #9`).

Nothing in the downloader computes the token. `getLegacy` mints one per stub download, scopes it
to that product's directory, gives it about a week, and embeds it in the stub after the bencoded
torrent between two four-byte tags. The client reads it as `cookieName`/`cookieData` and applies
it with `InternetSetCookieW`, which is a `Cookie` header on the wire.

So this tool pulls the token out of the stub and sends it, and `info` prints it:

```
cdn token       : bcac=expires=1788256690~access=/applications/…/enUS/*~md5=70edef94…
```

Two consequences worth knowing:

- **Ask for a product code and it always works.** `fetch D2DV` downloads a fresh stub, which
  carries a fresh token. An old stub on disk may have an expired one.
- **An expired token cannot be re-signed** — the signing key is Blizzard's and is not in the
  binary. Get a new stub. `--cookie` overrides it if you have one from elsewhere.

A bare `.torrent` carries no token, so it will 403 against Blizzard's host. Use a stub, pass
`--cookie`, or point `--base` somewhere that does not check.

## Watching the real downloader

`proxy` stands a logging HTTP proxy in front of it. WinInet honours the proxy in Internet
Settings, so every request appears in full — including the headers WinInet adds that reading the
disassembly will never show you — and is forwarded on, so the download keeps working while it is
watched.

```
blizzard-legacy-dl proxy            # listens on :8888
```

Then, on the machine running the downloader, Internet Options -> Connections -> LAN settings ->
proxy, pointed at whatever host is running it. No administrator rights and no hosts file. HTTPS
is tunnelled through CONNECT and stays unreadable, which is fine — none of this is HTTPS.

## The whole sequence

`run` does what the client does, in the client's order, with no window:

```
blizzard-legacy-dl run D2XP -o ./out
```

```
1  stub          the embedded torrent
2  metainfo      name, infohash, pieces, files
3  config        --ini, in BlizzardDownloader.ini format
4  server config <host>/update/Downloader.ini, only with --server-config
5  servers       every URL, with the piece range each may serve
6  tracker       announce event=started, and merge any servers it hands back
7  pieces        fetch, verify, assemble
8  tracker       announce event=stopped
9  launch target printed, never run
```

Step 4 is the hardcoded `http://12.129.222.52/update/Downloader.ini` the real client asks for
before it transfers anything. That address has been dead for years and nothing recovers from
it — the client just waits out the connect timeout, which is most of the pause on startup. It
is off by default here for that reason.

The announce in steps 6 and 8 is built exactly as `Tracker_BuildAnnounceUrl` builds it:

```
?info_hash=..&peer_id=..&key=..&port=3724&uploaded=0&downloaded=0&left=1&event=started
```

The port is the literal string `3724` rather than any port the program listens on, and the
progress figures are asserted rather than measured — `started` always claims nothing is done,
`stopped` always claims everything is. The client sends only those two events; `&compact=1` and
`&event=completed` are in the binary with nothing referencing them.

### Piece order is not sequential

The client builds a vector of `{piece, availability}` pairs, runs `std::random_shuffle` over it,
then sorts by availability with a **non-stable** sort, so the shuffle survives as the tie-break
among equal scores. That is rarest-first with a random tie-break — but every one of these
torrents sets `disable p2p`, so there are no peers, every score is equal, and what is left is a
fresh random permutation on each run. It is why the real progress bar fills in scattered blocks
rather than left to right.

`run` and `fetch` do the same. `--sequential` turns it off.

### http or https

Whichever the URL says. `HttpWinInet_SendRequest` always passes
`RELOAD | NO_CACHE_WRITE | NO_UI`, and adds `INTERNET_FLAG_SECURE` when the cracked URL's scheme
is `INTERNET_SCHEME_HTTPS`; the port comes from the URL too. So `https://` and non-default ports
work — Blizzard simply never used them, so in practice every request these stubs make is
plaintext HTTP on port 80. A mirror given to `--base` may be either.

Two details of the real request that a wine capture will not show you, because wine's WinInet is
its own reimplementation: `acceptTypes` is NULL, so genuine WinInet sends **no** `Accept` header,
and `RELOAD` is what puts `Pragma: no-cache` on the wire rather than the program setting it.

## Commands

```
info    <stub>                     name, infohash, piece count, size, both URLs
stubs   -o <dir>                   download every product/locale/os stub there is
files   <stub>                     the payload's file list
plan    <stub> [n]                 piece count, URL for piece n, files it spans
fetch   <stub> [-o dir]            fetch every piece, verify it, assemble
        [--from n] [--to n] [--retries n] [--base url]
verify  <stub> [-o dir]            re-check an assembled payload piece by piece
proxy   [--port n]                 watch what the real downloader sends, verbatim
run     <stub> [-o dir]            the whole client sequence, headless
        [--ini f] [--server-config url] [--no-tracker] [--sequential]
```

`<stub>` is a product code (`D2XP`), a downloader `.exe`, a Mac `.zip`, or a plain `.torrent`.
A code is resolved through getLegacy on the spot. `-o` defaults to the current directory; the
payload always lands in a subdirectory named after the torrent, so nothing gets strewn about.

Files get preallocated at full length first, then each piece is written with `pwrite` into
whichever files it lands in. Pieces straddle file boundaries constantly, so this matters. It also
means a fetch resumes and does not care about order.

`verify` is useful on its own: it checks a copy you got some other way against Blizzard's piece
hashes.

`scripts/probe-applications.sh` maps the `/applications/` tree by asking for piece 0 of each
candidate. It checks the five known-good bases first and stops if they 403, since on a blocked
network every later 403 means nothing. Known live:

```
Diablo2/1.14B/{D2,LOD}/<locale>
StarCraft/1.15.2/Combo/<locale>      enUS is served as enUS-2
Warcraft3/1.27a2/{ROC,TFT}/<locale>
```

45 payloads, 40.5 GB. The Wayback Machine has nothing under this host, so probing from a machine
with access is the only way to find more.

## Library

```zig
const legacy = @import("legacy");
const meta = try legacy.fromStub(gpa, stub_bytes);
const url  = try meta.pieceUrl(gpa, 0, null);
try meta.verify(0, piece_bytes);
```

`zig build test` covers the bencode decoder, short final pieces and URL construction.
`scripts/roundtrip.py` covers the rest end to end: it builds a payload, serves it as numbered
pieces the way the CDN did, fetches it back through `--base`, and compares byte for byte. Both
run in CI, which is what keeps the download path honest now that there is nothing live to test
against.
