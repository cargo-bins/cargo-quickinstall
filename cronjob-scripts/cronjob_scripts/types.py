from typing import TypedDict


class CrateAndVersion(TypedDict):
    crate: str
    version: str


class CrateAndMaybeVersion(TypedDict):
    crate: str
    version: str | None
