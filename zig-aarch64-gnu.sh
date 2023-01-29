#!/bin/sh
# shellcheck disable=SC2068
exec zig cc -target aarch64-linux-gnu $@
