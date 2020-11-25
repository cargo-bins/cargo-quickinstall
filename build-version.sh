#!/bin/bash
set -euo pipefail

source .env

CRATE=${1?"USAGE: $0 CRATE"}
date

cargo install "$CRATE"

VERSION=$(
    cat ~/.cargo/.crates2.json | jq -r '
        .installs | to_entries[] | select(.key|startswith("'${CRATE}' ")) | .key
    ' | sed -e 's/^[^ ]* //' -e 's/ .*$//'
)

BINARIES=$(
    cat ~/.cargo/.crates2.json | jq -r '
        .installs | to_entries[] | select(.key|startswith("'${CRATE}' ")) | .value.bins | .[]
    '
)

TEMPDIR=$(mktemp -d)

echo "$VERSION"
echo "$BINARIES"

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
cd ~/.cargo/bin
tar -czf "${TEMPDIR}/${CRATE}-${VERSION}.tar.gz" $BINARIES

echo "${TEMPDIR}/${CRATE}-${VERSION}.tar.gz"

# TODO: find a way to programatically make a new package with name ${CRATE}.
# How does homebrew do it?
echo "uploading file"
curl \
    --upload-file "${TEMPDIR}/${CRATE}-${VERSION}.tar.gz" \
    -u"${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/${CRATE}-${VERSION}.tar.gz"

echo "publishing version"
curl \
    -X POST \
    -u"${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/publish"

rm -r "$TEMPDIR"
