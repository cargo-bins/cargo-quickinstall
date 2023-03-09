#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

get_build_os() {
    if [[ "$1" == "x86_64-apple-darwin" ]]; then
        echo "macos-latest"
    elif [[ "$1" == "aarch64-apple-darwin" ]]; then
        echo "macos-latest"
    elif [[ "$1" == "x86_64-unknown-linux-gnu" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "x86_64-unknown-linux-musl" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "x86_64-pc-windows-msvc" ]]; then
        echo "windows-latest"
    elif [[ "$1" == "aarch64-pc-windows-msvc" ]]; then
        echo "windows-latest"
    elif [[ "$1" == "aarch64-unknown-linux-gnu" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "aarch64-unknown-linux-musl" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "armv7-unknown-linux-musleabihf" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "armv7-unknown-linux-gnueabihf" ]]; then
        echo "ubuntu-20.04"
    else
        echo "Unrecognised build OS: $1"
        exit 1
    fi
}

main() {
    REPO_ROOT="$PWD"
    BRANCH=$(git branch --show-current)
    RECHECK="${RECHECK:-}"

    # If we are on the `actions` branch, it's because we're trying to develop a feature.
    # Mostly we want just want it to check a few packages and then fall back to triggering
    # a build of cargo-quickinstall.
    if [[ "${BRANCH:-}" == "actions" && "${CI:-}" == "true" ]]; then
        CRATE_CHECK_LIMIT=3
    else
        # Assumes that each target has 5 pending crates to build,
        # that will be 30 runs in total.
        CRATE_CHECK_LIMIT="${CRATE_CHECK_LIMIT:-5}"
    fi

    if ! git config user.name; then
        git config user.email "alsuren+quickinstall@gmail.com"
        git config user.name "trigger-package-build.sh"
    fi

    TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-$(cat supported-targets)}}"

    if [ ! -d "${TEMPDIR:-}" ]; then
        TEMPDIR="$(mktemp -d)"
    fi

    for TARGET_ARCH in $TARGET_ARCHES; do
        BUILD_OS=$(get_build_os "$TARGET_ARCH")

        rm -rf "/tmp/cargo-quickinstall-$TARGET_ARCH"
        git worktree remove -f "/tmp/cargo-quickinstall-$TARGET_ARCH" || true
        git branch -D "trigger/$TARGET_ARCH" || true

        git worktree add --force --force "/tmp/cargo-quickinstall-$TARGET_ARCH"
        cd "/tmp/cargo-quickinstall-$TARGET_ARCH"

        if git fetch origin "trigger/$TARGET_ARCH"; then
            git checkout "origin/trigger/$TARGET_ARCH" -B "trigger/$TARGET_ARCH"
        elif git checkout "trigger/$TARGET_ARCH"; then
            # pass
            true
        else
            # New branch with no history. Credit: https://stackoverflow.com/a/13969482
            git checkout --orphan "trigger/$TARGET_ARCH"
            git rm --cached -r . || true
            git commit -m "Initial Commit" --allow-empty
            git push origin "trigger/$TARGET_ARCH"
        fi

        EXCLUDE_FILE="$(mktemp 2>/dev/null || mktemp -t 'excludes').txt"
        TARGET_ARCH="$TARGET_ARCH" "$REPO_ROOT/print-build-excludes.sh" >"$EXCLUDE_FILE"

        cat "$EXCLUDE_FILE"

        if [[ "$RECHECK" != "1" ]]; then
            rm -rf "$TEMPDIR/crates.io-responses"
        fi

        env TARGET_ARCH="$TARGET_ARCH" \
            EXCLUDE_FILE="$EXCLUDE_FILE" \
            RECHECK="$RECHECK" \
            TEMPDIR="$TEMPDIR" \
            CRATE_CHECK_LIMIT="$CRATE_CHECK_LIMIT" \
            "$REPO_ROOT/next-unbuilt-package.sh" |
            # Use `-c` compact mode to output one json output per line
            jq --unbuffered -c ". + {build_os: \"$BUILD_OS\" , branch: \"$BRANCH\"}" |
            # trigger a workflow for each json object
            python3 "$REPO_ROOT/trigger-build-package-workflow.py"
    done
}

main
