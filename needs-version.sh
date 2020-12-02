#!/bin/bash

CRATE=${1?"USAGE: $0 CRATE"}
VERSION=$(curl --location --fail "https://crates.io/api/v1/crates/${CRATE}" | jq -r .versions[0].num)
TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

# FIXME: fetch the latest $VERSION from crates.io, and do this check early, before we've even thought about
# running `cargo install`
# FIXME: this filename wants to include the target triple or something.
if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 1
else
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building"
    exit 0
fi
