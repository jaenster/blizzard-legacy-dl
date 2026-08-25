# blizzard-legacy-dl

[![Discord](https://img.shields.io/badge/Discord-join%20the%20chat-5865F2?logo=discord&logoColor=white)](https://discord.gg/MHK2Dg9)

Downloads the legacy Blizzard games — Diablo II, StarCraft, Warcraft III — from Blizzard's own
servers, without running their downloader.

```
docker run --rm -v "$PWD:/data" ghcr.io/jaenster/blizzard-legacy-dl fetch D2XP -o /data
```

## Install

Grab a binary from the [releases](../../releases) page — Windows, macOS and Linux, x86-64 and
arm64, no runtime to install:

| | |
|-|-|
|Windows|`-x86_64-windows.exe`, `-aarch64-windows.exe`|
|macOS|`-aarch64-macos` (Apple silicon), `-x86_64-macos` (Intel)|
|Linux|`-x86_64-linux-musl`, `-aarch64-linux-musl` (static)|
|Docker|`ghcr.io/jaenster/blizzard-legacy-dl`|

Or install it in one line:

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/jaenster/blizzard-legacy-dl/main/install.sh | sh
```

```powershell
# Windows
irm https://raw.githubusercontent.com/jaenster/blizzard-legacy-dl/main/install.ps1 | iex
```

Both pick the right build for your machine and check it against the release's `SHA256SUMS`.
There is a Homebrew formula in `Formula/` for a tap.

Building from source is in [BUILD.md](BUILD.md).

## Usage

A product code is all it needs — it fetches the stub, its access token and the payload itself:

```sh
blizzard-legacy-dl fetch D2DV -o ./out            # Diablo II            1.5 GB
blizzard-legacy-dl fetch D2XP -o ./out            # Lord of Destruction  509 MB
blizzard-legacy-dl fetch STAR -o ./out            # StarCraft + Brood War
blizzard-legacy-dl fetch WAR3 -o ./out            # Reign of Chaos
blizzard-legacy-dl fetch W3XP -o ./out            # The Frozen Throne

blizzard-legacy-dl fetch D2XP --locale de-DE      # another language
blizzard-legacy-dl fetch STAR --os MAC            # the Mac build

blizzard-legacy-dl info D2DV                      # look before downloading
blizzard-legacy-dl fetch D2DV --to 20             # just the first 21 pieces
blizzard-legacy-dl verify D2DV -o ./out           # re-check what you have
```

Docker takes the same arguments:

```sh
docker run --rm -v "$PWD:/data" ghcr.io/jaenster/blizzard-legacy-dl fetch D2XP -o /data
```

Interrupted downloads resume: rerun the same command and every piece already on disk that
matches its hash is left alone, so only what is missing gets fetched.

Products are `D2DV` (Diablo II), `D2XP` (Lord of Destruction), `STAR` (StarCraft),
`WAR3` (Reign of Chaos) and `W3XP` (The Frozen Throne). `--os` is `WIN` or `MAC`.

`--locale` defaults to `en-US`. Which ones exist varies per product — `stubs` walks
`en-US en-GB de-DE es-ES es-MX fr-FR it-IT ja-JP ko-KR pl-PL pt-BR ru-RU zh-CN zh-TW` and keeps
whatever answers.

`-o` defaults to the current directory, and the payload always lands in a subdirectory named
after the torrent (`D2LOD-1.14b-Installer-enUS` and so on), so nothing is strewn about.

A downloader `.exe` you already have works in place of the code, as does a plain `.torrent`.

```
info    <stub>                     name, size, piece count, servers, token
files   <stub>                     the payload's file list
plan    <stub> [n]                 the URL for piece n and the files it spans
fetch   <stub> [-o dir]            fetch, verify and assemble
verify  <stub> [-o dir]            re-check an assembled payload against its piece hashes
run     <stub> [-o dir]            the full downloader sequence, printed step by step
stubs   -o <dir>                   download every product/locale/os stub there is
proxy   [--port n]                 log HTTP requests passing through, and forward them
```

Options: `--from n` `--to n` fetch a piece range, `--retries n`, `--base <url>` use a mirror,
`--cookie <v>` override the access token, `--sequential` fetch in order instead of shuffled,
`--ini <file>` read config, `--no-tracker` skip the announce.

`proxy` listens on loopback; pass `--bind 0.0.0.0` to point another machine at it, which makes
it an open relay for anything else on that network for as long as it runs.

Files are preallocated at full length, then each piece is written where it lands, so a fetch
resumes and does not care about order. `verify` is useful on its own against a copy you got
some other way.

## The access token

Every request needs a signed cookie, and without it the CDN answers 403 for every path:

```
Cookie: bcac=expires=<unix>~access=/applications/…/enUS/*~md5=<32 hex>
```

Tokens are minted per stub download, scoped to that product's directory, and last about a week.
This tool reads the token out of the stub and sends it; `info` prints it.

So **ask for a product code and it just works** — that fetches a fresh stub with a fresh token.
An old stub on disk may have expired, and an expired token cannot be renewed locally: get a new
stub. A bare `.torrent` carries no token at all; use `--cookie`, or `--base` to point somewhere
that does not check.

## How the payload is served

The stub carries a bencoded torrent. The HTTP source serves **one numbered file per piece** —
`<base>/0`, `<base>/1`, … — not the payload's files and not one ranged stream, which is why
fetching the base URL directly gets you nowhere. Each piece is checked against its SHA-1 from
the torrent before it is written.

`direct download` may name more than one server: it splits on `|`, and a `[...]` group in the
host expands, with `,` between items and `-` for an inclusive range, so `http://dl[1-3,7]/x` is
four servers. A `server list` entry serves only the piece range it names. The tracker, if one
answers, can supply more. `--base` accepts the same syntax.

Pieces are fetched in a random order rather than sequentially. `--sequential` turns that off.

## See also

[**d2r-cdn**](https://github.com/jaenster/d2r-cdn) — the same idea for the modern games. Diablo II:
Resurrected and everything else current is distributed over NGDP/TACT/CASC, a completely different
system to the piece-numbered HTTP source these legacy stubs use, so it is a separate tool.

Between them: `d2r-cdn` for anything Blizzard still ships through the modern CDN, this for the
last legacy builds of Diablo II, StarCraft and Warcraft III.
