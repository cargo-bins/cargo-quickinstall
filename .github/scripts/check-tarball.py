#!/usr/bin/env python3
"""Checks the entries of a package tarball before the Sign job signs it.

Clients untar the tarball straight into ~/.cargo/bin, and the build that made
it ran crate code, so only plain files with plain names may be signed.

The Sign job holds the signing key, so it runs this file from main, never from
the branch being built. Standard library only.

Usage: check-tarball.py TARBALL
"""

import re
import sys
import tarfile


# Proxies that rustup installs into ~/.cargo/bin.
RESERVED = {
    "cargo",
    "cargo-clippy",
    "cargo-fmt",
    "cargo-miri",
    "clippy-driver",
    "rls",
    "rust-analyzer",
    "rust-gdb",
    "rust-gdbgui",
    "rust-lldb",
    "rustc",
    "rustdoc",
    "rustfmt",
    "rustup",
}
NAME = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*")


def problems(members: list[tarfile.TarInfo]) -> list[str]:
    found = []
    if not members:
        found.append("the tarball is empty")
    seen = set()
    for m in members:
        name = m.name
        if not m.isreg():
            found.append(f"{name!r} is not a regular file")
        if not NAME.fullmatch(name) or name in (".", ".."):
            found.append(f"{name!r} is not a plain file name")
        if m.mode & 0o7000:
            found.append(f"{name!r} has mode {m.mode:o}")
        if name.lower().removesuffix(".exe") in RESERVED:
            found.append(f"{name!r} would replace a rustup proxy")
        # Windows and macOS file systems ignore case.
        if name.lower() in seen:
            found.append(f"{name!r} appears more than once")
        seen.add(name.lower())
    return found


def main() -> int:
    (path,) = sys.argv[1:]
    with tarfile.open(path, "r:gz") as tar:
        members = tar.getmembers()
    found = problems(members)
    for p in found:
        print(f"::error::{p}")
    if found:
        return 1
    print("entries:", ", ".join(m.name for m in members))
    return 0


if __name__ == "__main__":
    sys.exit(main())
