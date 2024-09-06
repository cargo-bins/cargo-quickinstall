#!/usr/bin/env python

from __future__ import annotations

if __name__ == "__main__" and __package__ is None:
    import sys
    from pathlib import Path

    # Add repo root to PYTHONPATH and make relative imports work
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "scripts"


from collections import Counter
import json
import os
import random
import subprocess
import time

import requests

from cronjob_scripts.get_latest_version import CrateVersionDict, get_latest_version
from cronjob_scripts.checkout_worktree import checkout_worktree_for_arch
from cronjob_scripts.stats import get_requested_crates

TARGET_ARCH_TO_BUILD_OS = {
    "x86_64-apple-darwin": "macos-latest",
    "aarch64-apple-darwin": "macos-latest",
    "x86_64-unknown-linux-gnu": "ubuntu-20.04",
    "x86_64-unknown-linux-musl": "ubuntu-20.04",
    "x86_64-pc-windows-msvc": "windows-latest",
    "aarch64-pc-windows-msvc": "windows-latest",
    "aarch64-unknown-linux-gnu": "ubuntu-20.04",
    "aarch64-unknown-linux-musl": "ubuntu-20.04",
    "armv7-unknown-linux-musleabihf": "ubuntu-20.04",
    "armv7-unknown-linux-gnueabihf": "ubuntu-20.04",
}


def main():
    target_arches = get_target_architectures()
    for target_arch in target_arches:
        trigger_for_arch(target_arch)


def trigger_for_arch(target_arch: str):
    print(f"Triggering builds for {target_arch}")

    build_os = get_build_os(target_arch)

    tracking_worktree_path = checkout_worktree_for_arch(target_arch)
    excludes = get_excludes(tracking_worktree_path, days=7, max_failures=5)

    popular_crates = get_popular_crates()
    requested_crates = get_requested_crates(period="1 day", arch=target_arch)

    possible_crates = set(popular_crates + requested_crates) - set(excludes)

    # check random crates up to a limit.
    check_limit = int(os.environ.get("CRATE_CHECK_LIMIT", 5))
    # Note that the old next-unbuilt-package.sh script actually checked the top 4 * CRATE_CHECK_LIMIT
    # crates from get-stats.sh + popular-crates.txt rather than shuffling the whole lot before checking.
    # The original script just looped through the whole list, but kept track of where it got to,
    # to avoid getting stuck on unbuildable crates.
    #
    # For now I'm trying to be roughly backwards compatible with the old script's numbers,
    # but I think that shuffling first is an important bugfixt. Once we are using crates.io sparse
    # index api without rate-limits, we can think about checking more crates.
    crates_to_check = random.sample(list(possible_crates), 4 * check_limit)
    if os.environ.get("RECHECK"):
        crates_to_check = ["cargo-quickinstall"] + crates_to_check

    repo_url = get_repo_url()
    branch = get_branch()
    builds_scheduled = 0
    for crate in crates_to_check:
        print(f"Checking {crate} for {target_arch}")
        version = get_current_version_if_unbuilt(
            repo_url=repo_url, crate=crate, target_arch=target_arch
        )
        if not version:
            continue

        no_default_features = "false"
        if crate == "gitoxide":
            features = "max-pure"
            no_default_features = "true"
        elif crate == "sccache":
            features = "vendored-openssl"
        else:
            features = ",".join(
                [feat for feat in version["features"].keys() if "vendored" in feat]
            )

        workflow_run_input = {
            "crate": crate,
            "version": version["vers"],
            "target_arch": target_arch,
            "features": features,
            "no_default_features": no_default_features,
            "build_os": build_os,
            "branch": branch,
        }
        print(f"Attempting to build {crate} {version['vers']} for {target_arch}")
        subprocess.run(
            ["gh", "workflow", "run", "build-package.yml", "--json", f"--ref={branch}"],
            input=json.dumps(workflow_run_input).encode(),
            check=True,
        )
        builds_scheduled += 1
        if builds_scheduled >= check_limit:
            print("Scheduled enough builds, exiting")
            break
        time.sleep(30)


def get_build_os(target_arch: str) -> str:
    try:
        return TARGET_ARCH_TO_BUILD_OS[target_arch]
    except KeyError:
        raise ValueError(f"Unrecognised target arch: {target_arch}")


def get_target_architectures() -> list[str]:
    target_arch = os.environ.get("TARGET_ARCH", None)
    if target_arch in TARGET_ARCH_TO_BUILD_OS:
        return [target_arch]

    if target_arch == "all":
        return list(TARGET_ARCH_TO_BUILD_OS.keys())

    try:
        rustc_version_output = subprocess.run(
            ["rustc", "--version", "--verbose"], capture_output=True, text=True
        )
        current_arch = [
            line.split("host: ")[1]
            for line in rustc_version_output.stdout.splitlines()
            if line.startswith("host: ")
        ][0]
        return [current_arch]
    except:
        raise ValueError(f"rustc did not tell us its host: {rustc_version_output}")


def get_popular_crates():
    with open(
        Path(__file__).resolve().parent.parent.joinpath("popular-crates.txt"), "r"
    ) as file:
        return [
            line.strip()
            for line in file
            if line.strip() != "" and not line.startswith("#")
        ]


def get_excludes(tracking_worktree_path: str, days: int, max_failures: int):
    """
    if a crate has reached `max_failures` failures in the last `days` days then we exclude it
    """
    failures = Counter()

    failure_filenames = list(Path(tracking_worktree_path).glob("*-*-*"))
    failure_filenames.sort(reverse=True)

    for failure_filename in failure_filenames[:days]:
        with open(failure_filename, "r") as file:
            failures.update(
                Counter(line.strip() for line in file if line.strip() != "")
            )

    return [crate for crate, count in failures.items() if count >= max_failures]


def get_repo_url() -> str:
    repo_env_var = os.environ.get("GITHUB_REPOSITORY")
    if repo_env_var:
        return f"https://github.com/{repo_env_var}"
    return subprocess.run(
        ["gh", "repo", "view", "--json", "url", "--jq", ".url"],
        capture_output=True,
        text=True,
    ).stdout.strip()


def get_branch() -> str:
    return subprocess.run(
        ["git", "branch", "--show-current"],
        capture_output=True,
        text=True,
    ).stdout.strip()


def get_current_version_if_unbuilt(
    repo_url: str,
    crate: str,
    target_arch: str,
) -> CrateVersionDict | None:
    try:
        version = get_latest_version(crate)
    except:
        print(f"Failed to get latest version for {crate}")
        return None

    url = f"{repo_url}/releases/download/{crate}-{version['vers']}/{crate}-{version['vers']}-{target_arch}.tar.gz"
    response = requests.head(url, allow_redirects=True)
    if response.ok:
        print(f"{url} already uploaded")
        return None
    # FIXME: handle rate limit errors?

    return version


if __name__ == "__main__":
    main()
