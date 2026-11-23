#!/bin/bash
# Builds a static libseccomp and libcap-ng for every target in $TARGETS
# (separated by spaces), into /opt/<library>/<target>. sandbox/Dockerfile
# runs it, and build-crate.sh points libseccomp-sys and capng at them, which
# virtiofsd needs.
#
# The C compiler is zig, through `cargo-zigbuild zig cc`, with the same zig
# targets and flags as sandbox/openssl/build.rs. The targets build at the same
# time.
set -euo pipefail

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT

# Downloads and unpacks a release tarball, checking its sha256.
fetch() {
    local url="$1" sha256="$2"
    curl --proto '=https' --tlsv1.2 -sSfL -o "$src/download.tar.gz" "$url"
    echo "$sha256  $src/download.tar.gz" | sha256sum -c -
    tar -xzf "$src/download.tar.gz" -C "$src"
    rm "$src/download.tar.gz"
}

fetch https://github.com/seccomp/libseccomp/releases/download/v2.6.1/libseccomp-2.6.1.tar.gz \
    501f66c667225d53791b97e1d7cf85ab764c297d04881f60f38f451c4b0ee1be
# Upstream publishes this one without a configure script.
fetch https://people.redhat.com/sgrubb/libcap-ng/libcap-ng-0.8.5.tar.gz \
    e4be07fdd234f10b866433f224d183626003c65634ed0552b02e654a380244c2
(cd "$src/libcap-ng-0.8.5" && touch NEWS && autoreconf -fi)

# Configures and builds the library in source directory $1 for target $2,
# into /opt/$1/$2, with the configure options that follow.
build() {
    local lib="$1" target="$2"
    shift 2
    local zig_target flags=""
    case "$target" in
        x86_64-unknown-linux-gnu) zig_target=x86_64-linux-gnu.2.17 ;;
        x86_64-unknown-linux-musl) zig_target=x86_64-linux-musl ;;
        aarch64-unknown-linux-gnu) zig_target=aarch64-linux-gnu.2.17 ;;
        aarch64-unknown-linux-musl) zig_target=aarch64-linux-musl ;;
        armv7-unknown-linux-gnueabihf) zig_target=arm-linux-gnueabihf.2.17 ;;
        armv7-unknown-linux-musleabihf) zig_target=arm-linux-musleabihf ;;
        *) echo "no zig target for $target" >&2; return 1 ;;
    esac
    case "$target" in
        armv7-*) flags=-mcpu=generic+v7a+vfp3-d32+thumb2-neon ;;
    esac

    local dir="$src/build/$lib-$target"
    mkdir -p "$dir"
    cd "$dir"
    "$src/$lib/configure" --host="$target" --prefix="/opt/${lib%-*}/$target" \
        --enable-static --disable-shared --disable-dependency-tracking "$@" \
        CC="cargo-zigbuild zig cc -- -fno-sanitize=all $flags -target $zig_target" \
        AR="cargo-zigbuild zig ar --" RANLIB="cargo-zigbuild zig ranlib --" \
        CFLAGS=-O2 > configure.log 2>&1 || { cat configure.log config.log >&2; return 1; }
    # Only the library and its headers, not the tools and tests.
    make -C src -j"$(nproc)" install > make.log 2>&1 || { cat make.log >&2; return 1; }
    if [ -d include ]; then
        make -C include install > /dev/null
    fi
}

pids=()
for target in $TARGETS; do
    build libseccomp-2.6.1 "$target" &
    pids+=($!)
    build libcap-ng-0.8.5 "$target" --without-python --without-python3 &
    pids+=($!)
done
for pid in "${pids[@]}"; do
    wait "$pid"
done
