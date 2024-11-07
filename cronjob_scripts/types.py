from typing import TypedDict


class CrateAndVersion(TypedDict):
    """May also be a Struct with the same fields, which would be hashable. Don't tell anyone."""

    crate: str
    version: str


class CrateAndMaybeVersion(TypedDict):
    """May also be a Struct with the same fields, which would be hashable. Don't tell anyone."""

    crate: str
    version: str | None
