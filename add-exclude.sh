#!/bin/bash
set -euxo pipefail

if [ $# != 1 ]; then
    echo "Usage: $0 /path/to/trigger/branch"
    exit 1
fi

cd "$1"

exclude="$(date +'%y-%m-%d')"
echo "${CRATE}" >>"$exclude"

git add "$exclude"
git --no-pager diff HEAD

git config user.email "alsuren+quickinstall@gmail.com"
git config user.name "build-package.yml:add-exclude.sh"

git commit -m "Generates/Updates \"$exclude\""

exec git push origin "trigger/$TARGET_ARCH"
