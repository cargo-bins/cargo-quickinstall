#!/bin/bash
set -euxo pipefail

cd "$(dirname "$0")"

CRATE=${1?"USAGE: $0 CRATE"}
date

features="${FEATURES:-}"
if [ -z "$features" ]; then
    feature_flag=""
else
    feature_flag="--features"
fi

no_default_features=""
if [ "${NO_DEFAULT_FEATURES:-}" = "true" ]; then
    no_default_features='--no-default-features'
fi

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
    TEMPDIR="$(mktemp -d)"
fi

# see crawler policy: https://crates.io/policies
curl_slowly() {
    sleep 1 && curl --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

install_zig_cc_and_config_to_use_it() {
    # Install cargo-zigbuild
    #
    # We use cargo-zigbuild instead of zig-cc for cargo-zigbuild has
    # built-in for certain quirks when used with cargo-build.
    pip3 install cargo-zigbuild

    export CARGO=cargo-zigbuild
    # Use our own pkg-config that fails for any input, since we cannot use
    # locally installed lib in cross-compilation.
    export PKG_CONFIG="$PWD/pkg-config-cross.sh"
}

REPO="$(./get-repo.sh)"

if [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -I --output /dev/null "${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "${CRATE}/${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz already uploaded. Skipping."
    exit 0
elif [ "${ALWAYS_BUILD:-}" != 1 ] && curl_slowly --fail -L --output "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz" "${REPO}/releases/download/${CRATE}-${VERSION}-${TARGET_ARCH}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"; then
    echo "copy-pasting from the old location rather than building from scratch" >&2
    echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
    exit 0
fi

# Install llvm
if [ "${RUNNER_OS?}" == "Windows" ]; then
    choco install llvm
elif [ "${RUNNER_OS?}" == "Linux" ]; then
    wget -O - https://apt.llvm.org/llvm.sh | sudo bash
    llvm_prefix="$(find /usr/lib/llvm-* -maxdepth 0 | sort --reverse | head -n 1)"

    PATH="${llvm_prefix}/bin:${PATH}"
    export PATH

    LD_LIBRARY_PATH="$(llvm-config --libdir):${LD_LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH
elif [ "${RUNNER_OS?}" == "macOS" ]; then
    brew install llvm

    LLVM_PREFIX="$(brew --prefix llvm)"

    PATH="${LLVM_PREFIX}/bin:${PATH:-}"
    export PATH

    DYLD_LIBRARY_PATH="${LLVM_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
    export DYLD_LIBRARY_PATH
else
    echo "Unsupported ${RUNNER_OS?}"
    exit 1
fi

# Install cargo-zigbuild if necessary
if [ "$TARGET_ARCH" == "aarch64-unknown-linux-gnu" ]; then
    install_zig_cc_and_config_to_use_it
elif [ "$TARGET_ARCH" == "x86_64-unknown-linux-musl" ]; then
    install_zig_cc_and_config_to_use_it
elif [ "$TARGET_ARCH" == "aarch64-unknown-linux-musl" ]; then
    install_zig_cc_and_config_to_use_it
elif [ "$TARGET_ARCH" == "armv7-unknown-linux-musleabihf" ]; then
    install_zig_cc_and_config_to_use_it
elif [ "$TARGET_ARCH" == "armv7-unknown-linux-gnueabihf" ]; then
    install_zig_cc_and_config_to_use_it
fi

# Install rustup target
rustup target add "$TARGET_ARCH"

# Start building!
CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1"
export CARGO_PROFILE_RELEASE_LTO="fat"
export OPENSSL_STATIC=1

build_and_install() {
    # shellcheck disable=SC2086
    cargo-auditable auditable install "$CRATE" \
        --version "$VERSION" \
        --target "$TARGET_ARCH" \
        --root "$CARGO_ROOT" \
        ${1:-} \
        $no_default_features \
        $feature_flag $features
}

# Some crates are published without a lockfile, so fallback to no `--locked`
# just in case of spurious failure.
build_and_install '--locked' || build_and_install

# Collect binaries
CARGO_BIN_DIR="${CARGO_ROOT}/bin"
CRATES2_JSON_PATH="${CARGO_ROOT}/.crates2.json"

BINARIES=$(
    jq -r '
        .installs | to_entries[] | select(.key|startswith("'"${CRATE}"' ")) | .value.bins | .[]
    ' "$CRATES2_JSON_PATH" | tr '\r' ' '
)

cd "$CARGO_BIN_DIR"
for file in $BINARIES; do
    if file "$file" | grep ': data$'; then
        echo "something wrong with $file. Should be recognised as executable."
        exit 1
    fi
done

if [ -z "$BINARIES" ]; then
    echo "\`cargo-install\` does not install any binaries!"
    exit 1
fi

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
#
# BINARIES is a space-separated list of files, so it can't be quoted
# shellcheck disable=SC2086
tar --format=v7 -c $BINARIES | gzip -9 -c >"${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"

echo "${TEMPDIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
