#!/bin/bash
# Runs build-crate.sh on a GitHub macOS runner as a separate user, under the
# Seatbelt profile next to this script, and copies the tarball to $TEMPDIR.
#
# The runner user has passwordless sudo, and the runner's credentials (a JWT
# that can write Actions caches and artifacts of this run) sit in its home.
# The build user has no sudo, its home is the only place it can write besides
# the temporary directories, and the runner's home is closed to it twice: by
# the profile and by its permissions. Every process it started is killed
# before the tarball is copied out.
#
# It runs twice: once to install Rust and to run build-crate.sh's fetch phase,
# which downloads the crate and its dependencies and runs no crate code, and
# then for its build phase, which does, under offline.sb as well, so without
# network.
#
# Needs CRATE, VERSION, TARGET_ARCH and TEMPDIR, and FEATURES and
# NO_DEFAULT_FEATURES like build-crate.sh.
set -euo pipefail

: "${CRATE?}" "${VERSION?}" "${TARGET_ARCH?}" "${TEMPDIR?}"

here="$(cd "$(dirname "$0")" && pwd)"
tarball="${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
# A new user for every build, so that nothing one build left in its home
# reaches the next (selfbuild.yml builds twice in one job).
user="qibuild$(openssl rand -hex 4)"
runner_home="$HOME"

sudo sysadminctl -addUser "$user" -password "$(openssl rand -hex 24)" >/dev/null 2>&1
sudo createhomedir -c -u "$user" >/dev/null 2>&1 || true
build_home="$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')"
if [ -z "$build_home" ] || [ ! -d "$build_home" ]; then
    echo "Could not create the home of $user"
    exit 1
fi

kill_build_user() {
    sudo launchctl bootout "user/$(id -u "$user")" >/dev/null 2>&1 || true
    sudo pkill -KILL -u "$user" || true
}
trap kill_build_user EXIT

sudo chmod 700 "$runner_home"

# The scripts, owned by root so that the build cannot change them. The
# workspace is in the runner's home, which the build user cannot read.
src="$(sudo mktemp -d /private/tmp/quickinstall-src.XXXXXX)"
sudo install -m 644 "$here/build.sb" "$src/build.sb"
cat "$here/build.sb" "$here/offline.sb" | sudo tee "$src/build-offline.sb" >/dev/null
sudo chmod 644 "$src/build-offline.sb"
sudo install -m 755 "$here/../build-crate.sh" "$src/build-crate.sh"
sudo chmod 755 "$src"

out="$build_home/out"

# Runs the command after the profile as the build user, under that profile.
# env -i: nothing from the runner's environment, ACTIONS_* and GITHUB_*
# included, reaches the build.
run_sandboxed() {
    local profile="$1"
    shift
    (
        cd /
        sudo -u "$user" -H env -i \
            HOME="$build_home" \
            USER="$user" \
            PATH="$build_home/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            CRATE="$CRATE" \
            VERSION="$VERSION" \
            TARGET_ARCH="$TARGET_ARCH" \
            FEATURES="${FEATURES:-}" \
            NO_DEFAULT_FEATURES="${NO_DEFAULT_FEATURES:-}" \
            OUT_DIR="$out" \
            /usr/bin/sandbox-exec \
            -D RUNNER_HOME="$runner_home" \
            -D BUILD_HOME="$build_home" \
            -f "$profile" \
            "$@"
    )
}

# shellcheck disable=SC2016 # expanded by the inner bash
run_sandboxed "$src/build.sb" /bin/bash -euo pipefail -c '
    cd "$HOME"
    mkdir -p "$OUT_DIR"
    arch="$(uname -m | sed s/arm64/aarch64/)"
    curl --proto "=https" --tlsv1.2 -sSf -o rustup-init \
        "https://static.rust-lang.org/rustup/dist/$arch-apple-darwin/rustup-init"
    chmod +x rustup-init
    ./rustup-init -y --quiet --profile minimal --no-modify-path --default-toolchain stable
    rm rustup-init
    PHASE=fetch exec "$0"
' "$src/build-crate.sh"

# Nothing from the first run may still be running: it could reach the network.
kill_build_user

run_sandboxed "$src/build-offline.sb" /usr/bin/env PHASE=build "$src/build-crate.sh"

kill_build_user

# Only a regular file, so that a symlink cannot make the upload pick up
# anything else.
if sudo test -L "$out/$tarball" || ! sudo test -f "$out/$tarball"; then
    echo "$tarball is missing or not a regular file"
    exit 1
fi
# The redirect runs as the runner user on purpose.
# shellcheck disable=SC2024
sudo cat "$out/$tarball" >"$TEMPDIR/$tarball"
echo "$TEMPDIR/$tarball"
