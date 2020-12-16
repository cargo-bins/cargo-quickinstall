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

curl_slowly --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"

VERSION=$(
    cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].num
)

TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

if curl_slowly --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
fi

cargo install "$CRATE" --version "$VERSION"

BINARIES=$(
    cat ~/.cargo/.crates2.json | jq -r '
        .installs | to_entries[] | select(.key|startswith("'${CRATE}' ")) | .value.bins | .[]
    '
)

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
cd ~/.cargo/bin
tar -czf "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" $BINARIES

echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
