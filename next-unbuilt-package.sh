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

CRATE_CHECK_LIMIT="${CRATE_CHECK_LIMIT:-20}"
re='^[0-9]+$'
if ! [[ $CRATE_CHECK_LIMIT =~ $re ]]; then
    CRATE_CHECK_LIMIT=20
fi

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
        # Limit max crate to check to 10 * CRATE_CHECK_LIMIT so that we can
        # randomly pick CRATE_CHECK_LIMIT from them, thus having different
        # POPULAR_CRATES in each run.
        python3 ./dedup-and-exclude.py "${EXCLUDE_FILE?}" "$((10 * CRATE_CHECK_LIMIT))" |
        # -n specifies number of lines to output
        shuf -n "${CRATE_CHECK_LIMIT}" ||
        # If we don't find anything (package stopped being popular?)
        # then fall back to doing a self-build.
        echo 'cargo-quickinstall'
)

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --silent --show-error --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

REPO="$(./get-repo.sh)"

for CRATE in $POPULAR_CRATES; do
    RESPONSE_DIR="$TEMPDIR/crates.io-responses/"
    RESPONSE_FILENAME="$RESPONSE_DIR/$CRATE.json"
    if [[ ! -f "$RESPONSE_FILENAME" ]]; then
        mkdir -p "$RESPONSE_DIR"
        curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$RESPONSE_FILENAME"
    fi
    VERSION=$(jq -r '.crate|.max_stable_version' "$RESPONSE_FILENAME")
    FEATURES=$(
        jq -r ".versions[] | select(.num == \"$VERSION\") | .features | keys[]" "$RESPONSE_FILENAME" |
            (grep "^vendored-libgit2\|vendored-openssl$" || true) |
            paste -s -d ',' -
    )

    if curl_slowly --location --fail -I --output /dev/null "${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
        echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Keep going." 1>&2
    else
        echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building" 1>&2
        echo "{\"crate\": \"$CRATE\", \"version\": \"$VERSION\", \"target_arch\": \"$TARGET_ARCH\", \"features\": \"$FEATURES\"}"
    fi
done
