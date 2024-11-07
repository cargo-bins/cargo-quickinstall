from __future__ import annotations

from typing import TypedDict


class CrateAndVersion(TypedDict):
    """May also be a Struct with the same fields, which would be hashable. Don't tell anyone."""

    crate: str
    version: str


class CrateAndMaybeVersion(TypedDict):
    """May also be a Struct with the same fields, which would be hashable. Don't tell anyone."""

    crate: str
    version: str | None


class GithubAsset(TypedDict):
    """
    an element in the output of `gh release view $tag --json assets`

    Also contains a bunch of other fields but I don't care right now.
    """

    name: str
