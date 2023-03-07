#!/bin/bash

set -euxo pipefail

cd "$(dirname "$0")"

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
    TEMPDIR="$(mktemp -d)"
fi

if [[ "${TARGET_ARCH-}" == "" ]]; then
    TARGET_ARCH=$(rustc --version --verbose | sed -n 's/host: //p')
    export TARGET_ARCH
fi

if [[ ! -f "${EXCLUDE_FILE?}" ]]; then
    exit 1
fi

RECHECK="${RECHECK:-}"

POPULAR_CRATES=$(
    if [ "$RECHECK" == 1 ]; then
        # always check quickinstall first for `make release`
        echo "cargo-quickinstall"
    fi
    (
        ./get-stats.sh |
            jq 'keys[]' |
            grep -F "${TARGET_ARCH}" |
            cut -d '/' -f 1 |
            cut -c2-

        # Remove comment and empty lines
        grep -v -e '^#' -e '^[[:space:]]*$' ./popular-crates.txt
    ) |
        # Remove duplicate lines, remove exclulded crates
        # Limit max crate to check to CRATE_CHECK_LIMIT, which is set to 1000
        # if it is not present.
        python3 ./dedup-and-exclude.py "${EXCLUDE_FILE?}" "${CRATE_CHECK_LIMIT:-1000}" ||
        # If we don't find anything (package stopped being popular?)
        # then fall back to doing a self-build.
        echo 'cargo-quickinstall'
)

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --silent --show-error --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

for CRATE in $POPULAR_CRATES; do
    RESPONSE_DIR="$TEMPDIR/crates.io-responses/"
    RESPONSE_FILENAME="$RESPONSE_DIR/$CRATE.json"
    if [[ ! -f "$RESPONSE_FILENAME" ]]; then
        mkdir -p "$RESPONSE_DIR"
        curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$RESPONSE_FILENAME"
    fi
    VERSION=$(jq -r '[ .versions[] | select(.yanked == false) ][0].num' "$RESPONSE_FILENAME")

    if curl_slowly --location --fail -I --output /dev/null "https://github.com/cargo-bins/cargo-quickinstall/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
        echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Keep going." 1>&2
    else
        echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building" 1>&2
        echo "::set-output name=crate_to_build::$CRATE"
        echo "::set-output name=version_to_build::$VERSION"
        echo "::set-output name=arch_to_build::$TARGET_ARCH"
        exit 0
    fi
done
# If there's nothing to build, just build ourselves.
VERSION=$(curl_slowly --location --fail "https://crates.io/api/v1/crates/cargo-quickinstall" | jq -r .versions[0].num)
echo "::set-output name=crate_to_build::cargo-quickinstall"
echo "::set-output name=version_to_build::$VERSION"
echo "::set-output name=arch_to_build::$TARGET_ARCH"
