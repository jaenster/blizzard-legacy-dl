# blizzard-legacy-dl

Read a **Blizzard legacy downloader** stub and fetch what it points at, without running it.

```
zig build
./zig-out/bin/blizzard-legacy-dl info  Downloader_Diablo2_enUS.exe
./zig-out/bin/blizzard-legacy-dl fetch Downloader_Diablo2_enUS.exe -o ./out
```

## Where the stubs come from

Blizzard still serves them, publicly and unauthenticated:

```
https://www.battle.net/download/getLegacy?product=<CODE>&locale=<LOCALE>&os=<WIN|MAC>
```

`product` is one of **`D2DV D2XP STAR WAR3 W3XP`** — every other Battle.net product code
(`DRTL`, `W2BN`, `DSHR`, `SSHR`, `D2ST`, `DIAB`, `W3DM`, ...) returns 400. `os` is `WIN` or `MAC`
and nothing else; there is no PowerPC or console axis. `locale` varies per product — D2DV answers
for `en-US en-GB de-DE es-ES fr-FR it-IT ko-KR pl-PL zh-TW`.

That is **85 combinations, and all 85 are distinct binaries** — the locale is baked in, not a flag.

## What the stub actually is

A BitTorrent client with the torrent **bencoded inside the executable**. Alongside the usual
`info` dictionary it carries Blizzard's own keys:

| key | meaning |
|-|-|
| `announce` | `http://<region>.tracker.worldofwarcraft.com:3724/announce` |
| `direct download` | the HTTP piece source — **this is the one that still works** |
| `launch target` / `mac launch target` | what to run after assembly |
| `locale`, `use pieces` | |

The trackers have been dead for years: all five regions still resolve in DNS to real Blizzard
addresses, and port 3724 is closed on every one. The downloader says so on screen — *"The tracker
is not responding"* — and downloads anyway, because the HTTP source is plugged into the same piece
machinery as a peer. It even appears in the peer list, with its URL where a peer id would go.

## The bit that is not obvious

**The HTTP source serves one numbered file per piece.** Not the payload's files, and not one
ranged stream:

```
<direct download>/0
<direct download>/1
...
<direct download>/2038
```

Which is why `curl`-ing the base URL, or any path from `info.files`, gets you nowhere. Each piece
is an independent object, independently verifiable against its SHA-1 in `info.pieces`, so they can
be fetched in **any order and in parallel** — that is why the real client's progress bar fills in
scattered blocks rather than left to right.

Established by reverse engineering `Blizzard Downloader 2.2.0.1285`
(pdb `…/tools-sc2-gm/downloader/release/Blizzard Downloader.pdb`, RSDS
`36D5DD12-AFE8-415F-9CF4-D109BE7FC832`):
`HttpDirect_RequestPiece` → `HttpWinInet_SendRequest`, which goes through **WinInet**, not the
`Http-get.cpp` socket path. The two send different agents, and that trips people up: the socket
path is the *tracker's* and says `Blizzard Downloader 2.2`, while the piece path comes from
`InternetOpenA("Blizzard Web Client", ...)`. The request is:

```
GET /applications/Diablo2/1.14B/LOD/enUS/0 HTTP/1.1
User-Agent: Blizzard Web Client
Host: rogue.blizzard.com.edgesuite.net
Pragma: no-cache
Connection: Keep-Alive
```

No Accept, no Referer, no Range, no token, no cookie, no session. A retry appends
`?<shuffled alphabet>` purely to miss the CDN cache. `Range:` appears only when the metainfo has a
`chunk length` larger than `piece length`, which none of these do.

## A caveat worth stating plainly

The `rogue.blizzard.com.edgesuite.net` property is behind an **Akamai access rule keyed on the
client**, not on the request. From a machine Blizzard's downloader works on, the requests above
work. From elsewhere every path returns `403 AkamaiGHost` — including `/` — while a sibling
property like `dist.blizzard.com.edgesuite.net` returns a normal 404 for a missing path. Nothing
you put in the request changes that; this tool cannot conjure access it does not have.

## Commands

```
info    <stub.exe>                 name, infohash, piece count, size, both URLs
files   <stub.exe>                 the payload's file list
plan    <stub.exe> [n]             piece count, the URL for piece n, and the files it spans
fetch   <stub.exe> -o <dir>        fetch every piece, verify each, assemble
        [--from n] [--to n] [--retries n]
verify  <stub.exe> -o <dir>        re-verify an assembled payload piece by piece
```

Files are preallocated at full length up front, and each piece is written with `pwrite` into
whichever files it spans — pieces straddle file boundaries constantly — so a `fetch` is resumable
and order-independent. `verify` re-reads and re-hashes, so it also checks a copy obtained some
other way against Blizzard's own piece hashes.

## Finding what else is up there

`scripts/probe-applications.sh` enumerates the `/applications/` tree by asking for piece `0` of
each candidate - a payload existing and its piece 0 existing are the same question, and a range
request makes it free. It self-tests against the five known-good bases first and refuses to keep
going if they do not answer, because that means you are on a blocked network and every later 403
would be meaningless.

Confirmed live, from the stubs' own torrents:

    Diablo2/1.14B/{D2,LOD}/<locale>
    StarCraft/1.15.2/Combo/<locale>      (enUS is served as enUS-2)
    Warcraft3/1.27a2/{ROC,TFT}/<locale>

45 payloads, 40.5 GB in total. The Wayback Machine has nothing indexed under this host, so
probing from a machine with access is the only way to map it.

## Library

```zig
const legacy = @import("legacy");
const meta = try legacy.fromStub(gpa, stub_bytes);
const url  = try meta.pieceUrl(gpa, 0, null);
try meta.verify(0, piece_bytes);
```

`zig build test` covers the bencode decoder, short final pieces, and URL construction.
