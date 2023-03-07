#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

CRATE=${1?"USAGE: $0 CRATE"}
date

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
    TEMPDIR="$(mktemp -d)"
fi

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

REPO="$(git config --get remote.origin.url)"

if [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -I --output /dev/null "${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
elif [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -L --output "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" "${REPO}/releases/download/${CRATE}-${VERSION}-${TARGET_ARCH}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "copy-pasting from the old location rather than building from scratch" >&2
    echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
    exit 0
fi

if [ "$TARGET_ARCH" == "x86_64-unknown-linux-musl" ]; then
    CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')

    # Compiling against musl libc is failing despite installing the musl-tools
    # deb.  Falling back to Rust's Alpine container whose default target
    # is x86_64-unknown-linux-musl.
    podman run --name=official-alpine-rust docker.io/library/rust:alpine sh -c "set -euxo pipefail; apk update && apk add build-base curl; curl --location --silent --show-error --fail https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-$TARGET_ARCH.tgz | gunzip -c | tar -xvvf -; ./cargo-binstall binstall -y cargo-auditable; rm -f \$CARGO_HOME/.crates.toml \$CARGO_HOME/.crates2.json; CARGO_PROFILE_RELEASE_CODEGEN_UNITS=\"1\" CARGO_PROFILE_RELEASE_LTO=\"fat\" OPENSSL_STATIC=1 cargo auditable install $CRATE --version $VERSION --locked"
    podman cp official-alpine-rust:/usr/local/cargo/.crates2.json "${CARGO_ROOT}/"
    podman cp official-alpine-rust:/usr/local/cargo/bin "${CARGO_ROOT}/"
    podman rm -fv official-alpine-rust

    CARGO_BIN_DIR="${CARGO_ROOT}/bin"
    CRATES2_JSON_PATH="${CARGO_ROOT}/.crates2.json"
elif [ "$TARGET_ARCH" == "aarch64-unknown-linux-gnu" ]; then
    mkdir -p zigfolder
    curl "$(curl -q https://ziglang.org/download/index.json | jq 'to_entries | map([.key, .value])[1][1]["x86_64-linux"] | .tarball' | sed -e 's/^"//' -e 's/"$//')" | tar -xJ -C zigfolder --strip-components 1

    export PATH="$PWD/zigfolder:$PATH"
    rustup target add "$TARGET_ARCH"
    if ! [ -f "$HOME/.cargo/config" ]; then
        echo "[target.aarch64-unknown-linux-gnu]" >>~/.cargo/config
        echo "linker = \"$PWD/zig-aarch64.sh\"" >>~/.cargo/config
    fi

    CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')

    CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1" CARGO_PROFILE_RELEASE_LTO="fat" OPENSSL_STATIC=1 CC="$PWD/zig-aarch64.sh" cargo auditable install "$CRATE" --version "$VERSION" --target "$TARGET_ARCH" --root "$CARGO_ROOT" --locked

    CARGO_BIN_DIR="${CARGO_ROOT}/bin"
    CRATES2_JSON_PATH="${CARGO_ROOT}/.crates2.json"
else
    rustup target add "$TARGET_ARCH"
    CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1" CARGO_PROFILE_RELEASE_LTO="fat" OPENSSL_STATIC=1 cargo auditable install "$CRATE" --version "$VERSION" --target "$TARGET_ARCH" --root "$CARGO_ROOT" --locked

    CARGO_BIN_DIR="${CARGO_ROOT}/bin"
    CRATES2_JSON_PATH="${CARGO_ROOT}/.crates2.json"
fi

BINARIES=$(
    jq -r '
        .installs | to_entries[] | select(.key|startswith("'"${CRATE}"' ")) | .value.bins | .[]
    ' "$CRATES2_JSON_PATH" | tr '\r' ' '
)

cd "$CARGO_BIN_DIR"
for file in $BINARIES; do
    if file "$file" | grep ': data$'; then
        echo "something wrong with $file. Should be recognised as executable."
        exit 1
    fi
done

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
#
# BINARIES is a space-separated list of files, so it can't be quoted
# shellcheck disable=SC2086
tar --format=v7 -c $BINARIES | gzip -9 -c >"${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"

echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
