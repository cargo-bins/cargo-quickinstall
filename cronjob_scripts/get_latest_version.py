from __future__ import annotations

import json
import functools
from typing import TypedDict
import requests

import semver


class CrateVersionDict(TypedDict):
    """
    A returned row from the crates.io index API.

    Note that the returned row also includes all of the fields from the jsonschema at
    https://doc.rust-lang.org/cargo/reference/registry-index.html#json-schema
    but I can't be bothered typing them right now.
    """

    name: str
    vers: str
    features: dict[str, list[str]]


def get_index_url(crate: str):
    """
    Packages with 1 character names are placed in a directory named 1.
    Packages with 2 character names are placed in a directory named 2.
    Packages with 3 character names are placed in the directory 3/{first-character} where {first-character} is the first character of the package name.
    All other packages are stored in directories named {first-two}/{second-two} where the top directory is the first two characters of the package name, and the next subdirectory is the third and fourth characters of the package name. For example, cargo would be stored in a file named ca/rg/cargo.
    -- https://doc.rust-lang.org/cargo/reference/registry-index.html#index-files
    """
    if len(crate) == 0:
        raise ValueError("Empty crate name")
    if len(crate) == 1:
        return f"https://index.crates.io/1/{crate}"
    elif len(crate) == 2:
        return f"https://index.crates.io/2/{crate}"
    elif len(crate) == 3:
        return f"https://index.crates.io/3/{crate[0]}/{crate}"
    else:
        return f"https://index.crates.io/{crate[:2]}/{crate[2:4]}/{crate}"


@functools.lru_cache
def get_latest_version(
    crate: str, requested_version: str | None
) -> CrateVersionDict | None:
    """
    Calls the crates.io index API to get the latest version of the given crate.

    There is no rate limit on this api, so we can call it as much as we like.
    """
    url = get_index_url(crate)

    response = requests.get(url)
    if response.status_code == 404:
        print(f"No crate named {crate}")
        return None
    response.raise_for_status()

    max_version: CrateVersionDict | None = None
    max_parsed_version: semver.VersionInfo | None = None
    for line in response.text.splitlines():
        version = json.loads(line)
        if requested_version is not None and version["vers"] != requested_version:
            continue
        parsed_version = semver.VersionInfo.parse(version["vers"])
        if version["yanked"] or parsed_version.prerelease:
            continue

        if max_parsed_version is None or parsed_version > max_parsed_version:
            max_version = version
            max_parsed_version = parsed_version

    return max_version


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <crate>")
        sys.exit(1)

    version = get_latest_version(sys.argv[1])
    if version is not None:
        print(version["vers"])
