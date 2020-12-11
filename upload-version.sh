#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CRATE=${1?"USAGE: $0 CRATE VERSION TARGET_ARCH"}
VERSION=${2?"USAGE: $0 CRATE VERSION TARGET_ARCH"}
TARGET_ARCH=${3?"USAGE: $0 CRATE VERSION TARGET_ARCH"}

if [[ "$BINTRAY_USERNAME" = "" ]]; then
    # All files should be considered untrusted on the github actions box at this point?
    # Ugh. This is never going to fly.
    source .env
fi

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
        "https://api.bintray.com/packages/cargo-quickinstall/cargo-quickinstall" || echo "someone created $CRATE before us"
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
