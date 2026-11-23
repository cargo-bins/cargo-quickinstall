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
#
# PHASE splits it in two, so that the sandboxes can run the part that runs
# crate code without network:
#
#   fetch  downloads the crate and everything it can depend on into
#          CARGO_HOME, and the target if it is missing. It runs no crate code.
#   build  builds offline from what fetch left in CARGO_HOME, and packages.
#
# Without PHASE it does both.
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

phase="${PHASE:-all}"
case "$phase" in
fetch | build | all) ;;
*)
    echo "Unknown PHASE $phase"
    exit 1
    ;;
esac

if [[ "$TARGET_ARCH" == *"-linux-"* ]]; then
    install_zig_cc_and_config_to_use_it
fi

# Downloads $CRATE@$VERSION and every package that `cargo install` can need
# for it, with or without --locked and with any features, into CARGO_HOME.
#
# Everything here runs from / and names manifests with --manifest-path, as
# cargo reads .cargo/config.toml from the current directory up: a config in
# the crate could otherwise set a rustc wrapper and run code here.
fetch_crate() {
    local work crate_file src
    work="$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-fetch')"

    # The crate itself, and its index entry, through a package that depends
    # on it. That works for crates without a library too: cargo warns, but
    # resolves and downloads them anyway.
    mkdir -p "$work/root/src"
    : >"$work/root/src/lib.rs"
    cat >"$work/root/Cargo.toml" <<EOF
[package]
name = "quickinstall-fetch"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
$CRATE = "=$VERSION"
EOF
    (cd / && cargo fetch --manifest-path "$work/root/Cargo.toml")

    # What `cargo install --locked` builds with: the lockfile in the crate.
    crate_file="$(find "${CARGO_HOME:-$HOME/.cargo}/registry/cache" -name "$CRATE-$VERSION.crate" | head -n 1)"
    mkdir -p "$work/crate"
    tar -xzf "$crate_file" -C "$work/crate"
    src="$work/crate/$CRATE-$VERSION"
    if [ -f "$src/Cargo.lock" ]; then
        (cd / && cargo fetch --locked --manifest-path "$src/Cargo.toml") || true
    fi

    # And what it builds with without --locked: a fresh resolution, which,
    # with the crate as the root, covers all its features.
    # If that fails, the build still has what the package above resolved.
    rm -f "$src/Cargo.lock"
    (
        cd /
        cargo generate-lockfile --manifest-path "$src/Cargo.toml"
        cargo fetch --locked --manifest-path "$src/Cargo.toml"
    ) || true

    rm -rf "$work"
}

if [ "$phase" != build ]; then
    # The container image already has the target.
    if ! rustup target list --installed | grep -qx "$TARGET_ARCH"; then
        rustup target add "$TARGET_ARCH"
    fi
    fetch_crate
fi

if [ "$phase" = fetch ]; then
    exit
fi

# From here on nothing needs the network, and the sandboxes run it without.
export CARGO_NET_OFFLINE=true

# Start building!
CARGO_ROOT=$(mktemp -d 2>/dev/null || mktemp -d -t 'cargo-root')
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="1"
export CARGO_PROFILE_RELEASE_LTO="fat"
# Some crates turn on debug info in their release profile, such as ripgrep's
# `debug = 1`, and the package then ships it: ripgrep's x86_64 Linux tarball
# is 6 MB instead of 1.8 MB. Turn it off. With no debug info, cargo also strips
# it from the binary, and a `strip` the crate sets itself still applies.
export CARGO_PROFILE_RELEASE_DEBUG=false
export OPENSSL_STATIC=1
# The sandbox image has a static OpenSSL for each Linux target, see
# sandbox/Dockerfile. openssl-sys reads <TARGET>_OPENSSL_DIR, which unlike
# OPENSSL_DIR leaves alone any openssl-sys that build scripts need for the host.
if [ -d "/opt/openssl/$TARGET_ARCH" ]; then
    openssl_dir_var="$(tr 'a-z-' 'A-Z_' <<<"$TARGET_ARCH")_OPENSSL_DIR"
    export "$openssl_dir_var=/opt/openssl/$TARGET_ARCH"
fi
export CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse

# cargo-zigbuild's CMake toolchain file sets CMAKE_SYSTEM_NAME, so CMake
# cross-compiles even for x86_64 on x86_64. Some CMake projects can't be built
# that way, such as MySQL's client library, which diesel_cli's mysql-bundled
# feature builds: it runs try_run() checks and runs programs it has just
# built. So for the x86_64 targets, which the build machine can run, use a
# toolchain file that builds natively with the same compilers.
# For aarch64, use a toolchain file that cross-compiles like cargo-zigbuild's,
# but builds MySQL's build tools for the host.
if [[ "$TARGET_ARCH" = x86_64-unknown-linux-* ]]; then
    export "CMAKE_TOOLCHAIN_FILE_${TARGET_ARCH//-/_}=$PWD/cmake/linux-native-toolchain.cmake"
elif [[ "$TARGET_ARCH" = aarch64-unknown-linux-* ]]; then
    export "CMAKE_TOOLCHAIN_FILE_${TARGET_ARCH//-/_}=$PWD/cmake/linux-cross-toolchain.cmake"
fi

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

collect_binaries() {
    if [ -f "$CRATES2_JSON_PATH" ]; then
        jq -r '
            (.installs // {}) | to_entries[] | select(.key|startswith("'"${CRATE}"' ")) | .value.bins | .[]
        ' "$CRATES2_JSON_PATH" | tr '\r' ' '
    fi
}

# Prints the features that the crate's binary named after the crate needs,
# separated by commas, read from the manifest that `cargo install` unpacked.
bin_required_features() {
    local src manifest
    src="${CARGO_HOME:-$HOME/.cargo}/registry/src"
    manifest="$(find "$src" -mindepth 2 -maxdepth 2 -type d -name "$CRATE-$VERSION" 2>/dev/null | head -n 1)/Cargo.toml"
    if [ -f "$manifest" ]; then
        cargo metadata --manifest-path "$manifest" --no-deps --offline --format-version 1 |
            jq -r --arg name "$CRATE" '
                .packages[0].targets[]
                | select(.kind == ["bin"] and .name == $name)
                | (."required-features" // []) | join(",")
            '
    fi
}

BINARIES=$(collect_binaries)

# Some crates put their binary behind a feature that is not on by default,
# and then `cargo install` succeeds without installing anything. Turn on what
# the binary named after the crate needs and build again. Other binaries are
# left off: those are usually examples or development tools.
if [ -z "$BINARIES" ]; then
    required_features="$(bin_required_features)"
    if [ -n "$required_features" ]; then
        echo "Building again with the features that bin \"$CRATE\" needs: $required_features"
        features="${features:+$features,}$required_features"
        feature_flag="--features"
        build_and_install '--locked' || build_and_install
        BINARIES=$(collect_binaries)
    fi
fi

if [ -z "$BINARIES" ]; then
    echo "\`cargo-install\` does not install any binaries!"
    exit 1
fi

cd "$CARGO_BIN_DIR"
for file in $BINARIES; do
    if file "$file" | grep ': data$'; then
        echo "something wrong with $file. Should be recognised as executable."
        exit 1
    fi
done

# Package up the binaries so that they can be untarred in ~/.cargo/bin
#
# TODO: maybe we want to make a ~/.cargo-quickinstall/bin to untar into,
# and add symlinks into ~/.cargo/bin, to aid debugging?
#
# BINARIES is a space-separated list of files, so it can't be quoted
# shellcheck disable=SC2086
tar --format=v7 -c $BINARIES | gzip -9 -c >"${OUT_DIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"

echo "${OUT_DIR}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
