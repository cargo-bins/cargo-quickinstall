#!/bin/bash

set -euxo pipefail

needs_version() {
}

for CRATE in $(
  # FIXME: find a better naming scheme for this so that it can be parsed more easily
  ./get-stats.sh |
    jq -r '.aggregations.my_agg.buckets | map(.key)| .[]' |
    sed -n 's:^/api/crate/::p' |
    sed 's/-[0-9].*$//'
); do

  VERSION=$(curl --location --fail "https://crates.io/api/v1/crates/${CRATE}" | jq -r .versions[0].num)
  TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')

  if curl --fail -I --output /dev/null "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Keep going."
  else
    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building"
    echo "::set-output name=crate_to_build::$CRATE"
    echo "::set-output name=version_to_build::$VERSION"
    echo "::set-output name=arch_to_build::$TARGET_ARCH"
    exit 0
  fi
done
# If there's nothing to build, just build ourselves.
echo "cargo-quickinstall"
