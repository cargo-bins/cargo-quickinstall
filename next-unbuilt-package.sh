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

REPO="$(./get-repo.sh)"

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --silent --show-error --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

RESPONSE_DIR="$TEMPDIR/crates.io-responses/"
mkdir -p "$RESPONSE_DIR"

filter_already_built_crates() {
    # shellcheck disable=SC2141
    while IFS='$\n' read -r CRATE; do
        # Fetch crates.io info
        RESPONSE_FILENAME="$RESPONSE_DIR/$CRATE.json"
        if [[ ! -f "$RESPONSE_FILENAME" ]]; then
            if ! curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$RESPONSE_FILENAME"; then
                echo "crates.io does not have ${CRATE}, continue" >&2
                continue
            fi
        fi
        is_valid_json="$(jq 'has("crate") and has("versions")' "$RESPONSE_FILENAME")"
        if [ "$is_valid_json" != "true" ]; then
            echo "crates.io does not have ${CRATE}, continue" >&2
            continue
        fi
        VERSION="$(jq -r '.crate|.max_stable_version' "$RESPONSE_FILENAME")"
        if [ -z "$VERSION" ] || [ "$VERSION" == "null" ]; then
            echo "crates.io does not have ${CRATE}, continue" >&2
            continue
        fi

        url="${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
        if curl_slowly --location --fail -I --output /dev/null "$url"; then
            echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Keep going." >&2
        else
            echo "$CRATE"
        fi
    done
}

POPULAR_CRATES=$(
    (
        (
            ./get-stats.sh |
                jq -r 'keys[]' |
                grep -F "${TARGET_ARCH}" |
                cut -d '/' -f 1
        ) ||
            # If we don't find anything (package stopped being popular?)
            # then fall back to doing a self-build.
            echo 'cargo-quickinstall'

        # Remove comment and empty lines
        #
        # grep might fail due to broken pipe, where ./dedup-and-exclude.py
        # exits early due to collecting enough output.
        grep -v -e '^#' -e '^[[:space:]]*$' ./popular-crates.txt || true

        if [ "$RECHECK" == 1 ]; then
            # always check quickinstall first for `make release`
            echo "cargo-quickinstall" || true
        fi
    ) |
        # Remove duplicate lines, remove exclulded crates
        # Limit max crate to check to 4 * CRATE_CHECK_LIMIT so that we can
        # randomly pick CRATE_CHECK_LIMIT from them, thus having different
        # POPULAR_CRATES in each run.
        python3 ./dedup-and-exclude.py "${EXCLUDE_FILE?}" "$((4 * CRATE_CHECK_LIMIT))" |
        filter_already_built_crates |
        # -n specifies number of lines to output
        shuf -n "${CRATE_CHECK_LIMIT}"
)

for CRATE in $POPULAR_CRATES; do
    RESPONSE_FILENAME="$RESPONSE_DIR/$CRATE.json"

    VERSION=$(jq -r '.crate|.max_stable_version' "$RESPONSE_FILENAME")
    NO_DEFAULT_FEATURES=""

    if [ "$CRATE" = "gitoxide" ]; then
        FEATURES='max-pure'
        NO_DEFAULT_FEATURES='true'
    elif [ "$CRATE" = "sccache" ]; then
        FEATURES="vendored-openssl"
    else
        FEATURES=$(
            jq -r ".versions[] | select(.num == \"$VERSION\") | .features | keys[]" "$RESPONSE_FILENAME" |
                (grep "vendored" || true) |
                paste -s -d ',' -
        )
    fi

    echo "${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz needs building" >&2
    echo "{\"crate\": \"$CRATE\", \"version\": \"$VERSION\", \"target_arch\": \"$TARGET_ARCH\", \"features\": \"$FEATURES\", \"no_default_features\": \"$NO_DEFAULT_FEATURES\"}"
done
