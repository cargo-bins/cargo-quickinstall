#!/bin/bash
set -euxo pipefail

mkdir -p "$TARGET_ARCH"

find "$TARGET_ARCH" | sort --reverse | head -n 7 | xargs cat
