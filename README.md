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

## The catch

`rogue.blizzard.com.edgesuite.net` returns 403 for every path, `/` and `/robots.txt` included.
It is not this tool sending the wrong thing, and it is not one blocked network:

- Blizzard's own `Downloader_Diablo2_enUS.exe`, run under wine behind a logging proxy, sends
  byte for byte what this tool sends — and gets the same 403. That is what `proxy` below is for;
  the comparison is a two-minute job, not a matter of opinion.
- Akamai tells the two cases apart. A hostname it has no configuration for answers
  `400, Reference #9`. This one answers `403, Reference #18`: a live property with a deny rule.
- It is not the caller's reputation either. `dist.blizzard.com`, `blzddist1-a.akamaihd.net` and
  the regional CDN names all answer the same machine with an ordinary 404.
- Denied from Dutch consumer broadband and from a German datacentre, over HTTP and HTTPS, on six
  edge addresses, and on Akamai's staging network.

All 44 Windows stubs — every product, every locale — point at that one host, so there is no
second base to fall back to. The piece protocol itself is understood and implemented; what is
missing is a host willing to serve it. `--base` points `fetch` at any mirror laid out the same
way, and `verify` checks whatever comes back against Blizzard's own piece hashes.

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
