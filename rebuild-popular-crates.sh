#!/bin/bash

# This script rebuilds the popular-crates.txt file from lib.rs
# In theory we could use the crates.io db dump.
# See https://github.com/cargo-bins/cargo-quickinstall/issues/268#issuecomment-2329308074
#
# get-popular-crates.sh also seems to re-implement the functionality of this script.
#
# pup can be installed via: go get github.com/ericchiang/pup
# uq can be installed using cargo-quickinstall

set -euo pipefail

which pup || (
    echo "pup can be installed via: go get github.com/ericchiang/pup"
    exit 1
)
which uq || (
    echo "uq can be installed using cargo-quickinstall"
    exit 1
)

function get_top() {
    curl --fail "https://lib.rs/$1" |
    pup ':parent-of(:parent-of(:parent-of(.bin))) json{}' |
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

function get_top_both() {
    (
        get_top command-line-utilities
        get_top development-tools/cargo-plugins
    ) | sort
}

function get_new_file_contents() {
    (
        grep -B10000 '####################################' popular-crates.txt
        get_top_both
    ) | uq
}

get_new_file_contents >popular-crates.txt.new
mv popular-crates.txt.new popular-crates.txt

echo "popular-crates.txt has been rebuilt. Please check the changes into git"
