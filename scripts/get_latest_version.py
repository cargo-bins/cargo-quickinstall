import json
from typing import Literal, TypedDict
import requests

import semver


def get_index_url(crate: str):
    """
    Packages with 1 character names are placed in a directory named 1.
    Packages with 2 character names are placed in a directory named 2.
    Packages with 3 character names are placed in the directory 3/{first-character} where {first-character} is the first character of the package name.
    All other packages are stored in directories named {first-two}/{second-two} where the top directory is the first two characters of the package name, and the next subdirectory is the third and fourth characters of the package name. For example, cargo would be stored in a file named ca/rg/cargo.
    -- https://doc.rust-lang.org/cargo/reference/registry-index.html#index-files
    """
    if len(crate) == 1:
        return f"https://index.crates.io/1/{crate}"
    elif len(crate) == 2:
        return f"https://index.crates.io/2/{crate}"
    elif len(crate) == 3:
        return f"https://index.crates.io/3/{crate[0]}/{crate}"
    else:
        return f"https://index.crates.io/{crate[:2]}/{crate[2:4]}/{crate}"


class CrateVersionDict(TypedDict):
    name: str
    vers: str
    features: dict[str, list[str]]


def get_latest_version(crate: str) -> CrateVersionDict:
    """
    Calls the crates.io index API to get the latest version of the given crate.

    There is no rate limit on this api, so we can call it as much as we like.

    Note that the return type also includes all of the fields from the jsonschema at
    https://doc.rust-lang.org/cargo/reference/registry-index.html#json-schema
    but I can't be bothered typing them right now.
    """
    url = get_index_url(crate)

    # FIXME: handle 404s
    response = requests.get(url)
    versions = [json.loads(line) for line in response.text.splitlines()]
    unyanked_versions = [
        version
        for version in versions
        if not version["yanked"]
        and not semver.VersionInfo.parse(version["vers"]).prerelease
    ]

    # FIXME: check that rust actually agrees with semver when it comes to pre-release versions etc.
    unyanked_versions.sort(key=lambda v: semver.VersionInfo.parse(v["vers"]))

    return unyanked_versions[-1]


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <crate>")
        sys.exit(1)

    print(get_latest_version(sys.argv[1])["vers"])
