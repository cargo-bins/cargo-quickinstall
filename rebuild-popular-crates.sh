#!/bin/bash

function get_top() {
    curl https://lib.rs/$1 > ./temp.html
    cat temp.html |
        pup ':parent-of(:parent-of(:parent-of(.bin))) json{}' |
        jq -r '.[] |
            (.children[1].children|map(select(.class == "downloads").title)[0]// "0 ")
            + ":" +
            (.children[0].children[0].text)' |
        sort -gr |
        grep -v / |
        head -n 100 |
        sed s/^.*:// |
        sort
    rm ./temp.html
}

top_crates=""
top_crates="${top_crates} $(get_top command-line-utilities)"
top_crates="${top_crates} $(get_top development-tools/cargo-plugins)"
top_crates=`echo ${top_crates} | uniq | tr " " "\n" | sort`

echo ------------------------------------
echo "${top_crates}"
