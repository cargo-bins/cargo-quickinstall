#!/bin/bash
set -euxo pipefail

if [ $# != 1 ]; then
    echo "Usage: $0 variables-as-json"
    exit 1
fi

echo "$1" | gh workflow run build-package.yml --json
