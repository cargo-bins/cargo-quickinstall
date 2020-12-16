#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

git log -p "trigger/${TARGET?}" |
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
    cat
