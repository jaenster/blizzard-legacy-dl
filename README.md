# blizzard-legacy-dl

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
|Windows|`blizzard-legacy-dl-x86_64-windows.exe`|
|macOS|`blizzard-legacy-dl-aarch64-macos` (Apple silicon), `-x86_64-macos` (Intel)|
|Linux|`blizzard-legacy-dl-x86_64-linux-musl`, `-aarch64-linux-musl` (static)|
|Docker|`ghcr.io/jaenster/blizzard-legacy-dl`|

Building from source is in [BUILD.md](BUILD.md).

## Usage

Give it a product code and it fetches everything itself:

```
blizzard-legacy-dl info  D2DV
blizzard-legacy-dl fetch D2XP -o ./out
blizzard-legacy-dl fetch STAR --locale de-DE
```

Products are `D2DV` (Diablo II), `D2XP` (Lord of Destruction), `STAR` (StarCraft),
`WAR3` (Reign of Chaos) and `W3XP` (The Frozen Throne). `--locale` defaults to `en-US`;
D2 also has `en-GB de-DE es-ES fr-FR it-IT ko-KR pl-PL zh-TW`. `--os` is `WIN` or `MAC`.

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
