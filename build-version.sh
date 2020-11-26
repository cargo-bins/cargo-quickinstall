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

# FIXME: fetch the latest $VERSION from crates.io, and do this check early, before we've even thought about
# running `cargo install`
# FIXME: this filename wants to include the target triple or something.
if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}.tar.gz already uploaded. Skipping."
    exit 0
fi

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

CURL='curl --fail --location -w \n'

function curl_better() {
    if ! curl --fail --location -w '\n' "$@"; then
        echo "curl failed. Retrying for debug information and then exiting."
        curl --location -w '\n' "$@"
        false
    fi
}

if ! $CURL --output /dev/null "https://api.bintray.com/packages/cargo-quickinstall/cargo-quickinstall/${CRATE}"; then
    echo "package '${CRATE}' not found"

    curl --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"

    LICENSE=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].license | sed 's:/:", ":g')
    REPOSITORY=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .crate.repository)

    curl_better \
        --user "${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
        --header "Content-Type: application/json" \
        --data '
            {
                "name": "'"${CRATE}"'",
                "public_download_numbers": true,
                "public_stats": true,
                "vcs_url": "'"${REPOSITORY}"'",
                "licenses": ["'"${LICENSE}"'"]
            }' \
        "https://api.bintray.com/packages/cargo-quickinstall/cargo-quickinstall"
fi

echo "uploading file"
$CURL \
    --upload-file "${TEMPDIR}/${CRATE}-${VERSION}.tar.gz" \
    --user "${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/${CRATE}-${VERSION}.tar.gz"

echo "publishing version"
$CURL \
    -X POST \
    --user "${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/publish"

rm -r "$TEMPDIR"
