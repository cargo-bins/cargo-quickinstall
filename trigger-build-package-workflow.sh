#!/bin/bash
set -euxo pipefail

if [ $# != 1 ]; then
    exit
fi

echo "$1" | gh workflow run build-package.yml --json
