#!/bin/bash
set -euxo pipefail

GLIBC_VERSION="${GLIBC_VERSION:-2.17}"

cd "$(dirname "$0")"

CRATE=${1?"USAGE: $0 CRATE"}
date

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
    TEMPDIR="$(mktemp -d)"
fi

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

REPO="$(./get-repo.sh)"

if [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -I --output /dev/null "${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
fi

if [[ "$TARGET_ARCH" == *"-linux-gnu"* ]]; then
    CARGO_TARGET_ARCH="${TARGET_ARCH}.${GLIBC_VERSION}"
fi

export CRATE VERSION TARGET_ARCH CARGO_TARGET_ARCH

# Runs build-crate.sh in a container (sandbox/Dockerfile).
#
# On GitHub's runners, the runner user has passwordless sudo. With root, a
# build script or proc macro could read the job's runtime token out of the
# runner's memory, and with that token write caches that other workflows on
# the same branch restore, or replace artifacts of this run. Inside the
# container it sees only the scripts and the output directory, and the token
# is never there.
#
# Do not use a job-level `container:` instead: the runner mounts the docker
# socket and its working directories into it, and runs actions with the
# runtime token inside it.
build_in_container() {
    local ids image toolchain tag out tarball
    tarball="${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
    out="$(mktemp -d)"

    # Use the image that .github/workflows/sandbox-image.yml published for
    # these inputs and the current stable Rust. Only that workflow can push
    # to it: the build jobs have no token that could.
    ids="$(sandbox/image-tag.sh)"
    read -r toolchain tag <<<"$ids"
    image="${SANDBOX_IMAGE:-ghcr.io/cargo-bins/cargo-quickinstall-sandbox}:$tag"
    if ! docker pull --quiet "$image"; then
        # Not published yet: the inputs changed on this branch, or a new
        # Rust was released within the hour. Build it here, before any crate
        # code runs, so nothing untrusted can have touched it.
        echo "::notice::$image is not published, building it here"
        image=quickinstall-sandbox
        docker build --pull --build-arg RUST_TOOLCHAIN="$toolchain" \
            --tag "$image" --file sandbox/Dockerfile .
    fi

    docker run --rm --init \
        --user "$(id -u):$(id -g)" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --volume "$PWD:/quickinstall:ro" \
        --volume "$out:/out" \
        --env HOME=/tmp/home \
        --env CARGO_HOME=/tmp/cargo-home \
        --env CRATE \
        --env VERSION \
        --env TARGET_ARCH \
        --env CARGO_TARGET_ARCH \
        --env FEATURES \
        --env NO_DEFAULT_FEATURES \
        --env OUT_DIR=/out \
        "$image" /quickinstall/build-crate.sh

    # Copy out only the tarball, and only if it is a regular file, so that a
    # symlink cannot make the upload pick up the runner's files.
    if [ -L "$out/$tarball" ] || [ ! -f "$out/$tarball" ]; then
        echo "$tarball is missing or not a regular file"
        exit 1
    fi
    cp "$out/$tarball" "${TEMPDIR}/$tarball"
    rm -rf "$out"
    echo "${TEMPDIR}/$tarball"
}

if [ -n "${SANDBOX:-}" ] && [ "${RUNNER_OS?}" = Linux ]; then
    build_in_container
    exit
fi

# Install llvm, and protoc for crates that compile protobuf definitions in
# their build scripts. The sandbox image has both for Linux targets.
if [ "${RUNNER_OS?}" == "Windows" ]; then
    choco install llvm protoc
elif [ "${RUNNER_OS?}" == "Linux" ]; then
    sudo apt-get update
    sudo apt-get install -y clang llvm lld protobuf-compiler
elif [ "${RUNNER_OS?}" == "macOS" ]; then
    brew install llvm protobuf
else
    echo "Unsupported ${RUNNER_OS?}"
    exit 1
fi

if [ -n "${SANDBOX:-}" ] && [ "${RUNNER_OS?}" = macOS ]; then
    # As a separate user under sandbox-exec, see macos-sandbox/build.sh.
    export TEMPDIR
    exec macos-sandbox/build.sh
fi

if [ -n "${SANDBOX:-}" ] && [ "${RUNNER_OS?}" = Windows ]; then
    # As a separate user at Low integrity, see windows-sandbox/build.ps1.
    TEMPDIR="$(cygpath -w "$TEMPDIR")"
    export TEMPDIR
    exec pwsh -NoProfile -NonInteractive -File windows-sandbox/build.ps1
fi

OUT_DIR="$TEMPDIR" ./build-crate.sh
