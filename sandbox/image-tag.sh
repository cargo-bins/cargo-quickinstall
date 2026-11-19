#!/bin/bash
# Prints the Rust toolchain and the tag of the sandbox image, separated by a
# space, for example:
#
#     stable-2026-11-12 rust-2026-11-12-0123456789abcdef
#
# The toolchain is the current stable release, named by its date so that a
# build of the image installs exactly that release. The tag combines that date
# with a hash of the files the image is built from, so it changes whenever
# either of them does. .github/workflows/sandbox-image.yml publishes the image
# under this tag, and build-version.sh pulls it.
set -euo pipefail

cd "$(dirname "$0")/.."

# The manifest is almost 1 MB, and its date is on the second line.
manifest="$(curl --proto '=https' --tlsv1.2 -sSf --range 0-127 \
    https://static.rust-lang.org/dist/channel-rust-stable.toml)"
date="$(sed -n 's/^date = "\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)"$/\1/p' <<<"$manifest")"
if [ -z "$date" ]; then
    echo "Could not read the date of the stable Rust release" >&2
    exit 1
fi

# Everything sandbox/Dockerfile reads from the build context.
inputs="$(sha256sum sandbox/* supported-targets zigbuild-requirements.txt | sha256sum | cut -c1-16)"

echo "stable-$date rust-$date-$inputs"
