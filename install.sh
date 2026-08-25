#!/bin/sh
# Install blizzard-legacy-dl. macOS and Linux, x86-64 and arm64.
#
#   curl -fsSL https://raw.githubusercontent.com/jaenster/blizzard-legacy-dl/main/install.sh | sh
#
# Set DIR to choose where it lands; the default is /usr/local/bin, or ~/.local/bin when that is
# not writable. Set VERSION to pin a release instead of taking the latest.
set -eu

REPO=jaenster/blizzard-legacy-dl
VERSION="${VERSION:-latest}"

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux)  os=linux-musl ;;
  *) echo "unsupported OS: $(uname -s). Windows: use install.ps1" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
asset="blizzard-legacy-dl-${arch}-${os}"

if [ -n "${DIR:-}" ]; then dir="$DIR"
elif [ -w /usr/local/bin ] 2>/dev/null; then dir=/usr/local/bin
else dir="$HOME/.local/bin"
fi
mkdir -p "$dir"

if [ "$VERSION" = latest ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "downloading $asset"
curl -fsSL "$base/$asset" -o "$tmp/bin"

# Refuse to install something we could not verify, unless told to.
want=""
if curl -fsSL "$base/SHA256SUMS" -o "$tmp/sums" 2>/dev/null; then
  want=$(awk -v a="$asset" '$2 == a || $2 == "*"a {print $1}' "$tmp/sums" | head -1)
fi
if [ "${SKIP_CHECKSUM:-}" = 1 ]; then
  echo "skipping checksum verification (SKIP_CHECKSUM=1)"
elif [ -n "$want" ]; then
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/bin" | cut -d' ' -f1)
  else got=$(shasum -a 256 "$tmp/bin" | cut -d' ' -f1); fi
  if [ "$want" != "$got" ]; then
    echo "checksum mismatch for $asset (expected $want, got $got)" >&2
    exit 1
  fi
  echo "checksum ok"
else
  echo "could not read SHA256SUMS for $asset; refusing to install unverified." >&2
  echo "set SKIP_CHECKSUM=1 to override." >&2
  exit 1
fi

chmod +x "$tmp/bin"
mv "$tmp/bin" "$dir/blizzard-legacy-dl"
echo "installed $dir/blizzard-legacy-dl"
case ":$PATH:" in *":$dir:"*) ;; *) echo "note: $dir is not on your PATH" ;; esac
