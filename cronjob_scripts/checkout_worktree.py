from __future__ import annotations

from functools import lru_cache
import subprocess


@lru_cache
def checkout_worktree_for_target(target_arch: str):
    """
    Checkout a git worktree for the given target_arch, in /tmp.

    This is required for reading the exclude files.

    This is lifted directly from the old trigger-package-build.sh script, and is only expected to
    work on linux/macos with dash/bash.
    """
    worktree_path = f"/tmp/cargo-quickinstall-{target_arch}"
    bash_script = f"""
        set -eux

        rm -rf {worktree_path}
        git worktree remove -f {worktree_path} || true
        git branch -D "trigger/{target_arch}" || true

        git worktree add --force --force {worktree_path}
        cd {worktree_path}

        if git fetch origin "trigger/{target_arch}"; then
            git checkout "origin/trigger/{target_arch}" -B "trigger/{target_arch}"
        elif ! git checkout "trigger/{target_arch}"; then
            # New branch with no history. Credit: https://stackoverflow.com/a/13969482
            git checkout --orphan "trigger/{target_arch}"
            git rm --cached -r . || true
            git commit -m "Initial Commit" --allow-empty
            git push origin "trigger/{target_arch}"
        fi
    """
    subprocess.run(bash_script, shell=True, check=True, text=True)
    return worktree_path


def main():
    import sys

    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <target_arch>")
        sys.exit(1)

    worktree_path = checkout_worktree_for_target(sys.argv[1])
    print(f"checked out to {worktree_path}")


if __name__ == "__main__":
    main()
