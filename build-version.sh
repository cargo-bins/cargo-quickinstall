#!/bin/bash
set -euo pipefail

source .env

CRATE=${1?"USAGE: $0 CRATE"}
date

# FIXME: make a signal handler that cleans this up if we exit early.
TEMPDIR="$(mktemp -d)"

curl --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"

VERSION=$(
    cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].num
)

TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
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

# FIXME: split from here downwards into upload-version.sh or something.

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

    LICENSE=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].license | sed -e 's:/:", ":g' -e 's/ OR /", "/g')
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
    --upload-file "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" \
    --user "${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"

echo "publishing version"
$CURL \
    -X POST \
    --user "${BINTRAY_USERNAME}:${BINTRAY_API_KEY}" \
    "https://api.bintray.com/content/cargo-quickinstall/cargo-quickinstall/${CRATE}/${VERSION}/publish"

rm -r "$TEMPDIR"
