from __future__ import annotations

from functools import lru_cache
import subprocess

@lru_cache
def checkout_worktree_for_target(target: str):
    """
    Checkout a git worktree for the given target, in /tmp.

    This is required for reading the exclude files.

    This is lifted directly from the old trigger-package-build.sh script, and is only expected to
    work on linux/macos with dash/bash.
    """
    worktree_path = f"/tmp/cargo-quickinstall-{target}"
    bash_script = f"""
        set -eux

        rm -rf {worktree_path}
        git worktree remove -f {worktree_path} || true
        git branch -D "trigger/{target}" || true

        git worktree add --force --force {worktree_path}
        cd {worktree_path}

        if git fetch origin "trigger/{target}"; then
            git checkout "origin/trigger/{target}" -B "trigger/{target}"
        elif ! git checkout "trigger/{target}"; then
            # New branch with no history. Credit: https://stackoverflow.com/a/13969482
            git checkout --orphan "trigger/{target}"
            git rm --cached -r . || true
            git commit -m "Initial Commit" --allow-empty
            git push origin "trigger/{target}"
        fi
    """
    subprocess.run(bash_script, shell=True, check=True, text=True)
    return worktree_path
