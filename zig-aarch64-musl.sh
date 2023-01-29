#!/bin/sh
# shellcheck disable=SC2068
exec zig clang -target aarch64-linux-musl $@
