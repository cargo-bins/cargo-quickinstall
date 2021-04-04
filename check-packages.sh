#!/bin/bash
# shellcheck disable=SC2002
set -euo pipefail
cd "$(dirname "$0")"

GITHUB="https://github.com/alsuren/cargo-quickinstall/releases/download"
TEMPDIR=/tmp/check-packages
mkdir -p "$TEMPDIR"

function check_packages() {
    exitcode=0
    for tag in $(git tag | grep x86_64-apple-darwin); do
        # echo "$tag"
        if [[ ! -d "$TEMPDIR/$tag" ]]; then
            curl --silent --location --fail "${GITHUB}/${tag}/${tag}.tar.gz" > "$TEMPDIR/$tag.tar.gz"
            mkdir "$TEMPDIR/$tag"
            cat "$TEMPDIR/$tag.tar.gz" | tar -xzf - -C "$TEMPDIR/$tag"
            rm "$TEMPDIR/$tag.tar.gz"
        fi
        for file in "$TEMPDIR/$tag/"*; do
            if file "$file" | grep ': data$'; then
                exitcode=1
                git push --delete origin "$tag" || true
            fi
        done

        # rm -r "${TEMPDIR:?}/$tag"
    done
    exit $exitcode
}

check_packages
