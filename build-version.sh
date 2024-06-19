#!/bin/bash

set -euxo pipefail

cd "$(dirname "$0")"

GLIBC_VERSION="${GLIBC_VERSION:-2.17}"
CRATE="${CRATE?"USAGE: $0 CRATE"}"

if [[ "$TARGET_ARCH" == *"-linux-"* ]]; then
    llvm_prefix="$(find /usr/lib/llvm-* -maxdepth 0 | sort --reverse | head -n 1)"

    PATH="${llvm_prefix}/bin:${PATH}"
    export PATH

    LLVM_CONFIG_PATH="${llvm_prefix}/bin/llvm-config"
    export LLVM_CONFIG_PATH

    LIBCLANG_PATH="$(llvm-config --libdir)"
    export LIBCLANG_PATH

    LD_LIBRARY_PATH="${LIBCLANG_PATH}:${LD_LIBRARY_PATH:-}"
    export LD_LIBRARY_PATH

    LLVM_DIR="$(llvm-config --cmakedir)"
    export LLVM_DIR

    CARGO_TARGET_ARCH="${TARGET_ARCH}.${GLIBC_VERSION}"
fi

# Install rustup target
rustup toolchain install stable-"$TARGET_ARCH" --no-self-update --profile minimal

# Start building!
export CARGO_INSTALL_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1"
export CARGO_PROFILE_RELEASE_LTO="fat"
export OPENSSL_STATIC=1
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

build_and_install() {
    # shellcheck disable=SC2086
    cargo-auditable auditable install "$CRATE" \
        --version "${VERSION?}" \
        --target "${CARGO_TARGET_ARCH:-$TARGET_ARCH}" \
        ${1:-} \
        $CARGO_ARGS
}

# Some crates are published without a lockfile, so fallback to no `--locked`
# just in case of spurious failure.
build_and_install '--locked' || build_and_install

# Collect binaries
CARGO_BIN_DIR="${CARGO_INSTALL_ROOT}/bin"
CRATES2_JSON_PATH="${CARGO_INSTALL_ROOT}/.crates2.json"

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
tar --format=v7 -c $BINARIES | gzip -9 -c >"${TEMPDIR?}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
