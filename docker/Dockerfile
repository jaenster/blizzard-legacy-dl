# The CLI as a container, so nobody has to install Zig to use it.
#
# Zig cross-compiles, so the build stage always runs on the native runner arch and emits a
# static musl binary for the target arch - a multi-arch image without QEMU.
#
#   docker build -f docker/Dockerfile -t blizzard-legacy-dl .     (from the repo root)
#   docker run --rm blizzard-legacy-dl info D2XP
#   docker run --rm -v "$PWD:/data" blizzard-legacy-dl fetch D2XP -o /data
FROM --platform=$BUILDPLATFORM alpine:3.22 AS build
ARG ZIG_VERSION=0.16.0
ARG BUILDARCH
ARG TARGETARCH
RUN apk add --no-cache curl tar xz && \
    case "$BUILDARCH" in \
      amd64) host=x86_64 ;; \
      arm64) host=aarch64 ;; \
      *) echo "no zig build for $BUILDARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${host}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt && \
    ln -s "/opt/zig-${host}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# TARGETARCH is only set by buildx; fall back to the machine arch so a plain
# `docker build` works too.
RUN arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; esac; \
    fi && \
    case "$arch" in \
      amd64) zt=x86_64-linux-musl ;; \
      arm64) zt=aarch64-linux-musl ;; \
      *) echo "no zig target for '$arch'" >&2; exit 1 ;; \
    esac && \
    zig build -Doptimize=ReleaseFast -Dtarget="$zt" --prefix /out

FROM alpine:3.22
LABEL org.opencontainers.image.source="https://github.com/jaenster/blizzard-legacy-dl" \
      org.opencontainers.image.description="Read a Blizzard legacy downloader stub and fetch what it points at" \
      org.opencontainers.image.licenses="MIT"
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/bin/blizzard-legacy-dl /usr/local/bin/blizzard-legacy-dl
WORKDIR /data
VOLUME ["/data"]
ENTRYPOINT ["blizzard-legacy-dl"]
CMD ["--help"]
