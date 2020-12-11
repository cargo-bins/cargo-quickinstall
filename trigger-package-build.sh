#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

get_build_os() {
    if [[ "$1" == "x86_64-apple-darwin" ]]; then
        echo macos-latest
    elif [[ "$1" == "x86_64-apple-darwin" ]]; then
        echo ubuntu-20.04
    else
        echo "Unrecognised build OS: $1"
        exit 1
    fi
}

main() {
    for TARGET in x86_64-apple-darwin x86_64-unknown-linux-gnu; do
        BUILD_OS=$(get_build_os "$TARGET")

        rm -rf "/tmp/cargo-quickinstall-$TARGET"
        git worktree remove -f "/tmp/cargo-quickinstall-$TARGET" || true
        git branch -D "trigger/$TARGET" || true

        git worktree add --force --force "/tmp/cargo-quickinstall-$TARGET"
        cd "/tmp/cargo-quickinstall-$TARGET"

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

        if [[ -f package-info.txt ]]; then
            START_AFTER_CRATE=$(grep -F '::set-output name=crate_to_build::' package-info.txt | sed 's/^.*:://')
        else
            START_AFTER_CRATE=critcmp
        fi
        export START_AFTER_CRATE

        TARGET=$TARGET $REPO_ROOT/next-unbuilt-package.sh >package-info.txt

        CRATE=$(grep -F '::set-output name=crate_to_build::' package-info.txt | sed 's/^.*:://')

        mkdir -p .github/workflows/
        cat $REPO_ROOT/.github/workflows/build-package.yml.template |
            sed -e s/'[$]TARGET '/"$TARGET "/ \
                -e s/'[$]BUILD_OS '/"$BUILD_OS "/ \
                >.github/workflows/build-package.yml

        if ! git config user.name; then
            git config user.email "alsuren+quickinstall@gmail.com"
            git config user.name "trigger-package-build.sh"
        fi

        git add package-info.txt .github/workflows/build-package.yml
        git --no-pager diff HEAD
        git commit -am "Trigger build of $CRATE"

        git push origin "trigger/$TARGET"

        exit 0
    done
}

REPO_ROOT="$PWD"
BRANCH=$(git branch --show-current)

main
