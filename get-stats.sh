#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Uses https://sematext.com/docs/logs/search-through-the-elasticsearch-api/
# TODO:
# * Add a time range to the query.

QUERY=$(echo '
{
  "query": {
    "query_string": {
      "query": "*"
    }
  },
  "size": 0,
  "aggs": {
    "my_agg": {
      "terms": {
        "field": "proxy.path.raw",
        "size": 1000
      }
    }
  }
}
' | jq)
# echo "$QUERY"

curl \
  --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" \
  --silent \
  --show-error \
  -XGET \
  "https://warehouse-clerk-tmp.vercel.app/api/stats" \
  -d "$QUERY" | (
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
