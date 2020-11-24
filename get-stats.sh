#!/bin/bash

source .env

# Uses https://sematext.com/docs/logs/search-through-the-elasticsearch-api/
# TODO:
# * Switch to using the body-based API.
# * Add a time range to the query.
# * Add aggregation to the query.
curl -u "apiKey:${SEMATEXT_API_KEY}" -XGET "logsene-receiver.sematext.com/${SEMATEXT_APP_TOKEN}/_search?pretty&q=*"
