#!/bin/bash
set -euxo pipefail

find "$TARGET_ARCH" | sort --reverse | head -n 7 | xargs cat
