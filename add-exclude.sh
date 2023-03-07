#!/bin/bash
set -euxo pipefail

if [ $# != 1 ]; then
    echo "Usage: $0 /path/to/trigger/branch"
    exit 1
fi

cd "$1"
mkdir -p "$TARGET_ARCH"

exclude="${TARGET_ARCH}/$(date +'%y-%m-%d')"
echo "${CRATE}" >>"$exclude"
git add "$exclude"
git --no-pager diff HEAD
git commit -m "Generates \"$exclude\""
exec git push origin "trigger/$TARGET_ARCH"
