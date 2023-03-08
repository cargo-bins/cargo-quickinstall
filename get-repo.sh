#!/bin/bash
set -euxo pipefail

if [ -z "${GITHUB_REPOSITORY+x}" ]; then
    gh repo view --json url --jq '.url'
else
    echo "https://github.com/$GITHUB_REPOSITORY"
fi
