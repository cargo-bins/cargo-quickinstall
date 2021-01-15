#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

source .env

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
  -u "apiKey:${SEMATEXT_API_KEY}" \
  --silent \
  --show-error \
  -XGET \
  "https://logsene-receiver.sematext.com/${SEMATEXT_APP_TOKEN}/_search?pretty" \
  -d "$QUERY" |
  jq '.aggregations.my_agg.buckets' | (
  # Slight hack: if TARGET is specified then just print crate names one per line.
  # Otherwise print all counts as json.
  if [[ "${TARGET:-}" != "" ]]; then
    jq -r 'map(.key) | .[]' |
      (grep -F "${TARGET:-}" || true) |
      sed 's:^/api/crate/::' |
      sed 's:-[0-9].*::'
  else
    cat
  fi
)
