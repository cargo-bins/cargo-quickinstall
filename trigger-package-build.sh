#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

get_build_os() {
    if [[ "$1" == "x86_64-apple-darwin" ]]; then
        echo "macos-latest"
    elif [[ "$1" == "x86_64-unknown-linux-gnu" ]]; then
        echo "ubuntu-20.04"
    elif [[ "$1" == "x86_64-pc-windows-msvc" ]]; then
        echo "windows-latest"
    else
        echo "Unrecognised build OS: $1"
        exit 1
    fi
}

main() {
    REPO_ROOT="$PWD"
    BRANCH=$(git branch --show-current)

    if ! git config user.name; then
        git config user.email "alsuren+quickinstall@gmail.com"
        git config user.name "trigger-package-build.sh"
    fi

    TARGETS="${TARGETS:-x86_64-pc-windows-msvc x86_64-apple-darwin x86_64-unknown-linux-gnu}"

    for TARGET in $TARGETS; do
        BUILD_OS=$(get_build_os "$TARGET")

        rm -rf "/tmp/cargo-quickinstall-$TARGET"
        git worktree remove -f "/tmp/cargo-quickinstall-$TARGET" || true
        git branch -D "trigger/$TARGET" || true

        git worktree add --force --force "/tmp/cargo-quickinstall-$TARGET"
        cd "/tmp/cargo-quickinstall-$TARGET"
        EXCLUDE_FILE="/tmp/cargo-quickinstall-$TARGET/exclude.txt"

        if git fetch origin "trigger/$TARGET"; then
            git checkout "origin/trigger/$TARGET" -B "trigger/$TARGET"
        elif git checkout "trigger/$TARGET"; then
            # pass
            true
        else
            # New branch with no history. Credit: https://stackoverflow.com/a/13969482
            git checkout --orphan "trigger/$TARGET"
            git rm -r --force .
            git commit -am "Initial Commit" --allow-empty
        fi

        if [[ "${RECHECK:-}" == "1" || ! -f "$EXCLUDE_FILE" ]]; then
            TARGET="$TARGET" "$REPO_ROOT/print-build-excludes.sh" >"$EXCLUDE_FILE"
            git add "$EXCLUDE_FILE"
            git commit -m "Generate exclude.txt for $TARGET"
        fi

        if [[ -f package-info.txt && "${RECHECK:-}" != "1" ]]; then
            START_AFTER_CRATE=$(grep -F '::set-output name=crate_to_build::' package-info.txt | sed 's/^.*:://')
        else
            START_AFTER_CRATE=''
        fi

        env START_AFTER_CRATE="$START_AFTER_CRATE" \
            TARGET="$TARGET" \
            EXCLUDE_FILE="$EXCLUDE_FILE" \
            "$REPO_ROOT/next-unbuilt-package.sh" >package-info.txt

        CRATE=$(
            grep -F '::set-output name=crate_to_build::' package-info.txt |
                sed 's/^.*:://'
        )

        mkdir -p .github/workflows/
        # I like cat. Shut up.
        # shellcheck disable=SC2002
        cat "$REPO_ROOT/.github/workflows/build-package.yml.template" |
            sed -e s/'[$]TARGET'/"$TARGET"/ \
                -e s/'[$]BUILD_OS'/"$BUILD_OS"/ \
                -e s/'[$]BRANCH'/"$BRANCH"/ \
                >.github/workflows/build-package.yml

        git add package-info.txt .github/workflows/build-package.yml
        git --no-pager diff HEAD
        git commit -am "build $CRATE on $TARGET"

        if ! git push origin "trigger/$TARGET"; then
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
