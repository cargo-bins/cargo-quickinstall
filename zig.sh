#!/bin/bash
set -euxo pipefail

if [ "${TARGET_ARCH?}" = "aarch64-unknown-linux-gnu" ]; then
    TARGET_ARG=-target aarch64-linux-gnu
fi

# shellcheck disable=SC2068,2086
exec zig cc $TARGET_ARG $@
