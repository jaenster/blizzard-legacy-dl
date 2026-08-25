#!/usr/bin/env python3
"""End-to-end test: build a payload, serve it the way Blizzard's CDN served one, fetch it back.

Blizzard's host is gone, so nothing about the real thing can be exercised against it any more.
This stands up an equivalent: a torrent with the same Blizzard-specific keys, and a base URL
serving one numbered file per piece. `fetch --base` against it exercises the whole path —
bencode, piece hashing, straddled writes, assembly — and the result is compared byte for byte
with what went in.

    python3 scripts/roundtrip.py [path-to-binary]
"""
import hashlib, http.server, os, shutil, socketserver, subprocess, sys, tempfile, threading

BIN = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/blizzard-legacy-dl"
PIECE = 64 * 1024
NAME = "Roundtrip-Payload"
# Deliberately not multiples of the piece length, so pieces straddle file boundaries.
FILES = [("readme.txt", 1000), ("data/one.bin", 150_000), ("data/two.bin", 200_003)]


def ben(v):
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(ben(x) for x in v) + b"e"
    if isinstance(v, dict):
        return b"d" + b"".join(ben(k) + ben(v[k]) for k in sorted(v)) + b"e"
    raise TypeError(v)


def main():
    tmp = tempfile.mkdtemp(prefix="blz-roundtrip-")
    try:
        src, pieces_dir, out = (os.path.join(tmp, x) for x in ("src", "pieces", "out"))
        blob = b""
        for name, size in FILES:
            body = bytes((i * 37 + len(name)) % 251 for i in range(size))
            path = os.path.join(src, NAME, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "wb").write(body)
            blob += body

        os.makedirs(pieces_dir)
        hashes = b""
        for i in range(0, len(blob), PIECE):
            chunk = blob[i : i + PIECE]
            hashes += hashlib.sha1(chunk).digest()
            open(os.path.join(pieces_dir, str(i // PIECE)), "wb").write(chunk)
        n_pieces = len(hashes) // 20

        torrent = os.path.join(tmp, "roundtrip.torrent")
        open(torrent, "wb").write(ben({
            b"announce": b"http://tracker.invalid:3724/announce",
            b"direct download": b"http://127.0.0.1/unused",
            b"launch target": (NAME + "/readme.txt").encode(),
            b"locale": b"enUS",
            b"info": {
                b"name": NAME.encode(),
                b"piece length": PIECE,
                b"pieces": hashes,
                b"files": [
                    {b"length": size, b"path": [p.encode() for p in name.split("/")]}
                    for name, size in FILES
                ],
            },
        }))

        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a):
                pass

        os.chdir(pieces_dir)
        httpd = socketserver.TCPServer(("127.0.0.1", 0), Quiet)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:%d" % httpd.server_address[1]

        binary = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", BIN)) \
            if not os.path.isabs(BIN) else BIN
        # "run" rather than "fetch", so the whole client sequence is what gets covered, not
        # just the piece loop. The tracker in this fixture is deliberately unreachable.
        for verb in ("run", "verify"):
            cmd = [binary, verb, torrent, "-o", out] + (
                ["--base", base, "--no-tracker"] if verb == "run" else [])
            r = subprocess.run(cmd, capture_output=True, text=True)
            # Progress goes to stderr, so both streams matter.
            said = (r.stdout + r.stderr).strip()
            if r.returncode != 0:
                print(said)
                sys.exit("%s failed" % verb)
            print(said.splitlines()[-1] if said else "(no output)")

        for name, _ in FILES:
            a = open(os.path.join(src, NAME, name), "rb").read()
            b = open(os.path.join(out, NAME, name), "rb").read()
            if a != b:
                sys.exit("MISMATCH in %s" % name)
        print("round trip OK: %d pieces, %d files, %d bytes identical"
              % (n_pieces, len(FILES), len(blob)))
    finally:
        os.chdir("/")
        shutil.rmtree(tmp, ignore_errors=True)


main()
