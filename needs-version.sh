#!/bin/bash

set -euxo pipefail

CRATE=${1?"USAGE: $0 CRATE"}
VERSION=$(curl --location --fail "https://crates.io/api/v1/crates/${CRATE}" | jq -r .versions[0].num)
TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 1
else
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building"
    exit 0
fi
