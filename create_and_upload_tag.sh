#!/bin/bash
set -euxo pipefail

if [ $# != 1 ]; then
    echo Usage: "$0" tag
fi

tag="$1"

git tag "$tag"

exec git push origin "$1"
