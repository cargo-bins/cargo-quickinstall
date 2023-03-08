#!/bin/bash
set -euxo pipefail

echo "$0 is invoked with args" "${@:-}" >&2
echo Since we are doing cross compilation, we cannot use any locally installed lib >&2
echo Return 1 to signal error >&2

exit 1
