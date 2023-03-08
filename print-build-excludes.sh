#!/bin/bash
set -euxo pipefail

find . -type f |
    sort --reverse |
    head -n 7 |
    xargs cat |
    # Print any excluded crate occured more than 5 times only once
    awk '{cnt[$0]++; if (cnt[$0] == 5) print $0}'
