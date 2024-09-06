#!/bin/bash

# see also: rebuild-popular-crates.sh

set -euxo pipefail

which htmlq || (
    echo "htmlq can be installed using cargo-binstall"
    exit 1
)

function get_top() {
    curl --fail -L "https://lib.rs/$1" |
    htmlq ':parent-of(:parent-of(:parent-of(.bin))) json{}' |
    jq -r '.[] |
            (.children[1].children|map(select(.class == "downloads").title)[0]// "0 ")
            + ":" +
    (.children[0].children[0].text)' |
    sort -gr |
    grep -v / |
    grep -v ^0 |
    head -n 100 |
    tee /dev/fd/2 | # debugging goes to stderr
    sed s/^.*://
    
    echo "done with $1" 1>&2
}

(
    get_top command-line-utilities
    get_top development-tools/cargo-plugins
) | sort
