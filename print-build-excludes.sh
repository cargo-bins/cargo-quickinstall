#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

git log --format="%h %d" --since="3 months ago" "trigger/${TARGET_ARCH?}" |
    grep -v '(tag:' | # ignore things that successfully built
    sed 's/ .*$//' |
    xargs git show | # get the diffs
    grep -A1 '^\+::set-output name=crate_to_build::' |
    perl -p -e 's/\n//' |
    perl -p -e 's/$/\n/' |
    perl -p -e 's/--/\n/g' |
    sort |
    uniq -c |
    grep -v '^ *[1-3] ' |
    sed 's/^.*crate_to_build::\([^+]*\)[+].*$/\1/' |
    grep -v '^cargo-quickinstall$' |
    sort |
    uniq |
    cat || true # ugh. Something goes screwey when starting a new arch.
