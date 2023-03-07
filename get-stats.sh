#!/bin/bash
set -euo pipefail

# Note that it is also possible to get stats from previous months via
# /api/stats?year=2022&month=1

curl \
    --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" \
    --silent \
    --show-error \
    -XGET \
    "https://warehouse-clerk-tmp.vercel.app/api/stats" ||
    echo "Invalid json from stats server. Probably rate limit error. Skipping for now." >&2
