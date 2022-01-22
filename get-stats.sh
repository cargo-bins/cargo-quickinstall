#!/bin/bash
set -euo pipefail

curl \
  --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" \
  --silent \
  --show-error \
  -XGET \
  "https://warehouse-clerk-tmp.vercel.app/api/stats" | (
  # Slight hack: if TARGET is specified then just print crate names one per line.
  # Otherwise print all counts as json.
  if [[ "${TARGET:-}" != "" ]]; then
    jq -r 'keys | .[]' |
      (grep -F "${TARGET:-}" || true) |
      sed 's:/.*::'
  else
    jq '.'
  fi
)
