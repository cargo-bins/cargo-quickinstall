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

# This version failed on a compile error in its own source, so never build it
# again, see cronjob_scripts/root_crate_error.py.
if [ "${UNBUILDABLE:-}" = true ]; then
    echo "${CRATE} ${VERSION}" >>unbuildable
    git add unbuildable
fi

git --no-pager diff HEAD

git config user.email "alsuren+quickinstall@gmail.com"
git config user.name "build-package.yml:add-exclude.sh"

git commit -m "Generates/Updates \"$exclude\""

exec git push origin "trigger/$TARGET_ARCH"
