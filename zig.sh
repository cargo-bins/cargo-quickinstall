#!/bin/bash
set -euxo pipefail

zigfolder="$(dirname "$0")/zigfolder"

if [ "${TARGET_ARCH?}" = "aarch64-unknown-linux-gnu" ]; then
    TARGET_ARG="-target aarch64-linux-gnu"
else
    echo "Unsupported target ${TARGET_ARCH?}" >&2
    exit 1
fi

# shellcheck disable=SC2068,2086
exec "${zigfolder}/zig" cc $TARGET_ARG $@
