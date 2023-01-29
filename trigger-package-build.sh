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
    elif [[ "$1" == "aarch64-unknown-linux-gnu" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "aarch64-unknown-linux-musl" ]]; then
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
        CRATE_CHECK_LIMIT=10
        FORCE=1
    else
        CRATE_CHECK_LIMIT=1000
    fi

    if [[ ${FORCE:-} == 1 ]]; then
        ALLOW_EMPTY=--allow-empty
    else
        ALLOW_EMPTY=
    fi

    if ! git config user.name; then
        git config user.email "alsuren+quickinstall@gmail.com"
        git config user.name "trigger-package-build.sh"
    fi

    TARGET_ARCHES="${TARGET_ARCHES:-${TARGET_ARCH:-x86_64-pc-windows-msvc x86_64-apple-darwin aarch64-apple-darwin x86_64-unknown-linux-gnu x86_64-unknown-linux-musl aarch64-unknown-linux-gnu aarch64-unknown-linux-musl}}"

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
        EXCLUDE_FILE="/tmp/cargo-quickinstall-$TARGET_ARCH/exclude.txt"

        if git fetch origin "trigger/$TARGET_ARCH"; then
            git checkout "origin/trigger/$TARGET_ARCH" -B "trigger/$TARGET_ARCH"
        elif git checkout "trigger/$TARGET_ARCH"; then
            # pass
            true
        else
            # New branch with no history. Credit: https://stackoverflow.com/a/13969482
            git checkout --orphan "trigger/$TARGET_ARCH"
            git rm -r --force .
            git commit -am "Initial Commit" --allow-empty
        fi

        if [[ "$RECHECK" == "1" || "${REEXCLUDE:-}" == "1" || ! -f "$EXCLUDE_FILE" ]]; then
            TARGET_ARCH="$TARGET_ARCH" "$REPO_ROOT/print-build-excludes.sh" >"$EXCLUDE_FILE"
            git add "$EXCLUDE_FILE"
            git --no-pager diff HEAD
            git commit -m "Generate exclude.txt for $TARGET_ARCH" || echo "exclude.txt already up to date. Skipping."
            if [[ "${REEXCLUDE:-}" == "1" ]]; then
                continue
            fi
        fi

        if [[ -f package-info.txt && "$RECHECK" != "1" ]]; then
            START_AFTER_CRATE=$(grep -F '::set-output name=crate_to_build::' package-info.txt | sed 's/^.*:://')
        else
            START_AFTER_CRATE=''
        fi

        if [[ "$RECHECK" != "1" ]]; then
            rm -rf "$TEMPDIR/crates.io-responses"
        fi

        env START_AFTER_CRATE="$START_AFTER_CRATE" \
            TARGET_ARCH="$TARGET_ARCH" \
            EXCLUDE_FILE="$EXCLUDE_FILE" \
            RECHECK="$RECHECK" \
            TEMPDIR="$TEMPDIR" \
            CRATE_CHECK_LIMIT="$CRATE_CHECK_LIMIT" \
            "$REPO_ROOT/next-unbuilt-package.sh" >package-info.txt

        CRATE=$(
            grep -F '::set-output name=crate_to_build::' package-info.txt |
                sed 's/^.*:://'
        )
        VERSION=$(
            grep -F '::set-output name=version_to_build::' package-info.txt |
                sed 's/^.*:://'
        )

        # kill off the old location of this file
        git rm .github/workflows/build-package.yml || true

        mkdir -p .github/workflows/

        # I like cat. Shut up.
        sed \
            -e s/'[$]CRATE'/"$CRATE"/ \
            -e s/'[$]VERSION'/"$VERSION"/ \
            -e s/'[$]TARGET_ARCH'/"$TARGET_ARCH"/ \
            -e s/'[$]BUILD_OS'/"$BUILD_OS"/ \
            -e s/'[$]BRANCH'/"$BRANCH"/ \
            "$REPO_ROOT/.github/workflows/build-package.yml.template" \
            >".github/workflows/build-package-$TARGET_ARCH.yml"

        # FIXME: I don't think we need package-info.txt anymore.
        git add package-info.txt ".github/workflows/build-package-$TARGET_ARCH.yml"
        git --no-pager diff HEAD

        # $ALLOW_EMPTY is either --allow-empty or the empty string.
        # Adding quotes around this would add an empty positional argument to git,
        # which it would reject.
        # shellcheck disable=SC2086
        if ! git commit $ALLOW_EMPTY -am "build $CRATE $VERSION on $TARGET_ARCH"; then
            echo "looks like there's nothing to push"
            continue
        fi

        if ! git push origin "trigger/$TARGET_ARCH"; then
            echo "
                If you have updated .github/workflows/build-package.yml.template
                then you will need to run trigger-package-build.sh on your local machine
                first.
            "
            exit 1
        fi
    done
}

main
