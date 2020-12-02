#!/bin/bash
set -euo pipefail

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
        "size": 10
      }
    }
  }
}
' | jq)
# echo "$QUERY"

curl -u "apiKey:${SEMATEXT_API_KEY}" -XGET "logsene-receiver.sematext.com/${SEMATEXT_APP_TOKEN}/_search?pretty" -d "$QUERY"
