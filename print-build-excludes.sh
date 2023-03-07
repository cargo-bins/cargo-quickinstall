#!/bin/bash
set -euxo pipefail

mkdir -p "$TARGET_ARCH"

find "$TARGET_ARCH" -type f | sort --reverse | head -n 7 | xargs cat
