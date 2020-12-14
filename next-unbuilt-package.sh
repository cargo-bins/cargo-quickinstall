#!/bin/bash

set -euxo pipefail

cd "$(dirname "$0")"

POPULAR_CRATES=$(
  cat ./popular-crates.txt |
    grep -v '^#' |
    grep -A100 --line-regexp "${START_AFTER_CRATE-.*}" |
    tail -n +2 # drop the first line (the one that matched)
)

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
  TEMPDIR="$(mktemp -d)"
fi

if [[ "${TARGET-}" == "" ]]; then
  TARGET=$(rustc --version --verbose | sed -n 's/host: //p')
fi

# see crawler policy: https://crates.io/policies
curl_slowly() {
  sleep 1 && curl --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

for CRATE in $POPULAR_CRATES; do

  rm -rf "$TEMPDIR/crates.io-response.json"
  curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"
  VERSION=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].num)
  LICENSE=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].license | sed -e 's:/:", ":g' -e 's/ OR /", "/g')

  if [[ "$LICENSE" = "BSD-3-Clause" || "$LICENSE" = "non-standard" ]]; then
    # FIXME: I should really do some kind of license translation so that bintray will accept my packages.
    echo "Skipping ${CRATE} to avoid \"License 'BSD-3-Clause' does not exist\" error when uploading." 1>&2
  elif curl_slowly --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET}.tar.gz already uploaded. Keep going." 1>&2
  else
    echo "${CRATE}-${VERSION}-${TARGET}.tar.gz needs building" 1>&2
    echo "::set-output name=crate_to_build::$CRATE"
    echo "::set-output name=version_to_build::$VERSION"
    echo "::set-output name=arch_to_build::$TARGET"
    exit 0
  fi
done
# If there's nothing to build, just build ourselves.
VERSION=$(curl_slowly --location --fail "https://crates.io/api/v1/crates/cargo-quickinstall" | jq -r .versions[0].num)
echo "::set-output name=crate_to_build::cargo-quickinstall"
echo "::set-output name=version_to_build::$VERSION"
echo "::set-output name=arch_to_build::$TARGET"
