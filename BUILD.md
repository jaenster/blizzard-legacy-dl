# Building

Needs [Zig](https://ziglang.org/download/) 0.16.0 and nothing else.

```
zig build                       # -> zig-out/bin/blizzard-legacy-dl
zig build -Doptimize=ReleaseFast
zig build run -- info D2XP
```

## Cross-compiling

Zig cross-compiles without a toolchain per target, which is how the releases are produced:

```
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows  --prefix build/win
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos   --prefix build/mac
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl --prefix build/linux
```

Give each target its own `--prefix`; they all install a binary of the same name and will
otherwise overwrite one another.

Released targets: `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-macos`, `aarch64-macos`,
`x86_64-windows`, `aarch64-windows`. The Linux builds are static musl.

## Container

```
docker build -f docker/Dockerfile -t blizzard-legacy-dl .
docker run --rm -v "$PWD:/data" blizzard-legacy-dl fetch D2XP -o /data
```

The build stage runs on the native architecture and cross-compiles to the target, so multi-arch
images need no emulation.

## Tests

```
zig build test --summary all
```

Unit tests cover the bencode decoder, URL expansion, short final pieces and the tracker announce.
`src/e2e.zig` builds a payload, serves it as numbered pieces over a local socket, fetches it back
through the same code the CLI uses, and compares byte for byte.

## Library

The bencode and piece machinery is importable:

```zig
// build.zig.zon: .blizzard_legacy_dl = .{ .url = ... }
// build.zig:     .imports = &.{ .{ .name = "legacy", .module = dep.module("legacy") } }
const legacy = @import("legacy");

const meta = try legacy.fromStub(gpa, stub_bytes);
const url  = try meta.pieceUrl(gpa, 0, null);
try meta.verify(0, piece_bytes);
```

`fromStub` takes a downloader `.exe`, a `.torrent`, or a Mac `.zip`. `Metainfo` carries the file
list, piece hashes, servers and the CDN access token.
