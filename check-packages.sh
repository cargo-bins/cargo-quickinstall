#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

REPO="$(git config --get remote.origin.url)"
GITHUB="${REPO}/releases/download"
TEMPDIR=/tmp/check-packages
mkdir -p "$TEMPDIR"

function check_packages() {
    exitcode=0
    for tag in $(git tag | grep x86_64-apple-darwin); do
        # echo "$tag"
        if [[ ! -d "$TEMPDIR/$tag" ]]; then
            curl --silent --location --fail "${GITHUB}/${tag}/${tag}.tar.gz" >"$TEMPDIR/$tag.tar.gz"
            mkdir "$TEMPDIR/$tag"
            tar -xzf "$TEMPDIR/$tag.tar.gz" -C "$TEMPDIR/$tag"
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
