#!/bin/bash
# Builds $CRATE@$VERSION for $TARGET_ARCH and packages its binaries into
# $OUT_DIR/$CRATE-$VERSION-$TARGET_ARCH.tar.gz.
#
# This runs the crate's build scripts and proc macros, so treat everything it
# touches as untrusted. When SANDBOX is set, build-version.sh runs it in a
# container for Linux targets and as a separate user under sandbox-exec for
# macOS targets. For Windows targets it runs windows-sandbox/build-crate.ps1
# instead, which does the same and must be kept in step with this. It needs
# no privileges of its own.
set -euxo pipefail

cd "$(dirname "$0")"

: "${CRATE?}" "${VERSION?}" "${TARGET_ARCH?}" "${OUT_DIR?}"

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

export CARGO=cargo

install_zig_cc_and_config_to_use_it() {
    # Install cargo-zigbuild
    #
    # We use cargo-zigbuild instead of zig-cc for cargo-zigbuild has
    # built-in for certain quirks when used with cargo-build.
    # The container image already has it.
    if ! command -v cargo-zigbuild >/dev/null; then
        pip3 install -r zigbuild-requirements.txt
    fi

    export CARGO=cargo-zigbuild
    # Use our own pkg-config that fails for any input, since we cannot use
    # locally installed lib in cross-compilation.
    export PKG_CONFIG="$PWD/pkg-config-cross.sh"
}

if [[ "$TARGET_ARCH" == *"-linux-"* ]]; then
    install_zig_cc_and_config_to_use_it
fi

# The container image already has the target.
if ! rustup target list --installed | grep -qx "$TARGET_ARCH"; then
    rustup target add "$TARGET_ARCH"
fi

# Start building!
CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1"
export CARGO_PROFILE_RELEASE_LTO="fat"
export OPENSSL_STATIC=1
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

build_and_install() {
    # shellcheck disable=SC2086
    $CARGO install "$CRATE" \
        --version "$VERSION" \
        --target "${CARGO_TARGET_ARCH:-$TARGET_ARCH}" \
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
tar --format=v7 -c $BINARIES | gzip -9 -c >"${OUT_DIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"

echo "${OUT_DIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
