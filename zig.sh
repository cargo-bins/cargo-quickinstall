#!/bin/bash
set -euxo pipefail

if [ "${TARGET_ARCH?}" = "aarch64-unknown-linux-gnu" ]; then
    TARGET_ARG="-target aarch64-linux-gnu"
elif [ "${TARGET_ARCH?}" = "x86_64-unknown-linux-musl" ]; then
    TARGET_ARG="-target x86_64-linux-musl"
else
    echo "Unsupported target ${TARGET_ARCH?}" >&2
    exit 1
fi

# shellcheck disable=SC2068,2086
exec cargo-zigbuild zig cc -- $TARGET_ARG $@
