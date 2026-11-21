"""
Finds out whether a failed build failed on a compile error in the crate's own
source, from the build job's log.

Such a failure won't go away by building the same version again: the source
does not change, and nothing quickinstall can change about the environment
(libraries, tools, features) gets rid of it. That covers stub crates, whose
whole source is a compile_error!() pointing at the real crate, crates that only
build on unix built for Windows, and crates that no longer compile on the
current Rust. Errors in dependencies, build scripts and the linker don't
count: those may be fixed by a new release of a dependency, or by a change to
the build environment, like the static OpenSSL in the Linux sandbox.

Only the last `cargo install` attempt in the log counts, since build-crate.sh
retries without `--locked`, and that may fail differently.
"""

from __future__ import annotations

import re
import sys
from collections.abc import Iterable


# GitHub prefixes every line of a job log with a timestamp.
TIMESTAMP_RE = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
HEADER_RE = re.compile(r"^(error|warning|note|help)(\[\w+\])?: ")


def root_crate_error(crate: str, version: str, log: Iterable[str]) -> str | None:
    """
    Returns the first compile error whose primary location is in the source of
    `crate` `version` itself, in the last `cargo install` attempt in `log`, or
    None if there is none.
    """
    lines = [ANSI_RE.sub("", TIMESTAMP_RE.sub("", line.rstrip("\r\n"))) for line in log]

    installing = re.compile(
        rf"^\s*Installing {re.escape(crate)} v{re.escape(version)}\s*$"
    )
    start = 0
    for index, line in enumerate(lines):
        if installing.match(line):
            start = index

    # The unpacked source of the crate, in the registry cache of any CARGO_HOME,
    # with / or \ as the separator.
    root_source = re.compile(
        rf"[/\\]registry[/\\]src[/\\][^/\\]+[/\\]{re.escape(crate)}-{re.escape(version)}[/\\]"
    )
    error: str | None = None
    for line in lines[start:]:
        if header := HEADER_RE.match(line):
            error = line if header.group(1) == "error" else None
        elif error and line.lstrip().startswith("--> "):
            # The first location after the header is the primary one.
            if root_source.search(line):
                return error
            error = None
    return None


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <crate> <version> < job.log", file=sys.stderr)
        sys.exit(2)
    error = root_crate_error(sys.argv[1], sys.argv[2], sys.stdin)
    if error is None:
        sys.exit(1)
    print(error)


if __name__ == "__main__":
    main()
