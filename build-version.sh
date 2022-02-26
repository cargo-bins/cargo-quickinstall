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

if curl_slowly --fail -I --output /dev/null "https://github.com/alsuren/cargo-quickinstall/releases/download/${CRATE}-${VERSION}-${TARGET_ARCH}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
fi

rustup target add "$TARGET_ARCH"
if [[ "$TARGET_ARCH" == "aarch64-unknown-linux-gnu" ]]; then
    echo $PATH
    cargo install cargo-quickinstall
    cargo-quickinstall --dry-run cross
    cargo-quickinstall cross

    # I'm expecting this to fail if you try to build `cross` or `cargo-quickinstall`
    cross install "$CRATE" --version "$VERSION" --target "$TARGET_ARCH"

    cargo uninstall cargo-quickinstall
    exit 1
else
    cargo install "$CRATE" --version "$VERSION" --target "$TARGET_ARCH"
fi
>>>>>>> 381a499f (have a stab at building for aarch64-linux)

BINARIES=$(
    cat ~/.cargo/.crates2.json | jq -r '
        .installs | to_entries[] | select(.key|startswith("'${CRATE}' ")) | .value.bins | .[]
    ' | tr '\r' ' '
)


cd ~/.cargo/bin
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
tar -czf "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" $BINARIES

echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
