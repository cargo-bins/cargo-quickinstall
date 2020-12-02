#!/bin/bash

set -euxo pipefail

for crate in $(
  # FIXME: find a better naming scheme for this so that it can be parsed more easily
  ./get-stats.sh |
    jq -r '.aggregations.my_agg.buckets | map(.key)| .[]' |
    sed -n 's:^/api/crate/::p' |
    sed 's/-[0-9].*$//'
); do
  if ./needs-version.sh "$crate" 1>&2; then
    echo "$crate"
    exit 0
  fi
done
# If there's nothing to build, just build ourselves.
echo "cargo-quickinstall"
