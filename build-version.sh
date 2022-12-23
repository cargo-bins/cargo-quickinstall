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

if [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -I --output /dev/null "https://github.com/alsuren/cargo-quickinstall/releases/download/${CRATE}-${VERSION}-${TARGET_ARCH}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
fi

if [ "$TARGET_ARCH" == "x86_64-unknown-linux-musl" ]
then
    # Compiling against musl libc is failing despite installing the musl-tools
    # deb.  Falling back to Rust's Alpine container whose default target
    # is x86_64-unknown-linux-musl.
    podman run --name=official-alpine-rust docker.io/library/rust:alpine sh -c "apk add build-base; CARGO_PROFILE_RELEASE_CODEGEN_UNITS=\"1\" CARGO_PROFILE_RELEASE_LTO=\"fat\" OPENSSL_STATIC=1 cargo install $CRATE --version $VERSION"
    podman cp official-alpine-rust:/usr/local/cargo "${TEMPDIR}/"

    CARGO_BIN_DIR="${TEMPDIR}/cargo/bin"
    CRATES2_JSON_PATH="${TEMPDIR}/cargo/.crates2.json"
else
    rustup target add "$TARGET_ARCH"
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1" CARGO_PROFILE_RELEASE_LTO="fat" OPENSSL_STATIC=1 cargo install "$CRATE" --version "$VERSION" --target "$TARGET_ARCH"

    CARGO_BIN_DIR=~/.cargo/bin
    CRATES2_JSON_PATH=~/.cargo/.crates2.json
fi

BINARIES=$(
    cat $CRATES2_JSON_PATH | jq -r '
        .installs | to_entries[] | select(.key|startswith("'${CRATE}' ")) | .value.bins | .[]
    ' | tr '\r' ' '
)

cd $CARGO_BIN_DIR
for file in $BINARIES; do
    if file $file | grep ': data$'; then
        echo "something wrong with $file. Should be recognised as executable."
        exit 1
    fi
done

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
tar --format=v7 -czf "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" $BINARIES

echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
