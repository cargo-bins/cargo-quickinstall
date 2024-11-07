#!/usr/bin/env python

from __future__ import annotations


from collections import Counter
from functools import lru_cache
import json
import os
from pathlib import Path
import random
import subprocess
import time
from typing import List, cast

import requests

from cronjob_scripts.types import CrateAndMaybeVersion
from cronjob_scripts.architectures import get_build_os, get_target_architectures
from cronjob_scripts.checkout_worktree import checkout_worktree_for_target
from cronjob_scripts.get_latest_version import CrateVersionDict, get_latest_version
from cronjob_scripts.stats import get_requested_crates
from cronjob_scripts.crates_io_popular_crates import get_crates_io_popular_crates


"""
* construct the following list of crates (n lists for each target):
  * for each target:
    * the list of install requests with the "built-from-source" status in the last day (ordered by popularity, including versions - WARNING: this is very likely to result in the same crate being built many times in parallel if someone runs the cronjob manually on ci/locally)
    * the list of install requests with the "built-from-source" status in the last day (shuffled, including versions)
    * the list of install requests with any other status in the last day (shuffled, with versions stripped)
    * popular-crates.txt (shuffled)
    * a list with just cargo-quickinstall and nothing else
* shuffle the list of lists and then round-robin between each list:
  * take the head of the list
  * if we already checked this package for this target, skip it
  * if we already tried to build this package 5 times in the last 7 days, skip it (TODO: also record the version in the failure log?)
  * check its latest version + if we have a package built for it. If we don't have a package built for it, trigger a build
    * if we already triggered m package builds since the start of the run, exit (probably set this to n times the number of targets?)
* if we hit a github rate limit when doing this, this is fine and we just bomb out having made some progress?
* if we get to the end without triggering any builds then that's fine too: there's nothing to do.

"""


def main():
    import sys

    if len(sys.argv) > 1:
        print(
            "Usage: INFLUXDB_TOKEN= target= CRATE_CHECK_LIMIT= RECHECK= GITHUB_REPOSITORY= trigger-package-build.py"
        )
        if sys.argv[1] == "--help":
            exit(0)
        exit(1)

    targets = get_target_architectures()
    # FIXME: make a better type than tuple here.
    # We mean list of (type, target, list of crates and versions)
    queues: list[tuple[str, str, list[CrateAndMaybeVersion]]] = []

    # we shuffle the list of popular crates from crates.io once, and use it for every arch, to slightly
    # reduce the number of requests we need to make to crates.io. It probably isn't worth it though.
    popular_crates = get_crates_io_popular_crates()
    random.shuffle(popular_crates)

    for target in targets:
        queue = get_requested_crates(period="1 day", target=target)
        random.shuffle(queue)
        queues.append(("requested", target, cast(List[CrateAndMaybeVersion], queue)))
        queues.append(("popular", target, popular_crates.copy()))

        if os.environ.get("RECHECK"):
            queues.append(
                (
                    "self",
                    target,
                    [cast(CrateAndMaybeVersion, {"crate": "cargo-quickinstall"})],
                )
            )

    random.shuffle(queues)

    triggered_count = 0
    # FIXME: make this limit a constant or env var?
    for index in range(1000):
        for type, target, queue in queues:
            triggered = trigger_for_target(type, target, queue, index)
            time.sleep(1)
            if triggered:
                triggered_count += 1
                if triggered_count > 5 * len(targets):
                    print("Triggered enough builds, exiting")
                    return


def trigger_for_target(
    type: str, target: str, queue: list[CrateAndMaybeVersion], index: int
) -> bool:
    if len(queue) <= index:
        return False
    crate_and_maybe_version = queue[index]
    print(f"Triggering {type} build for {target}: {crate_and_maybe_version}")
    crate = crate_and_maybe_version["crate"]
    requested_version = crate_and_maybe_version.get("version")

    tracking_worktree_path = checkout_worktree_for_target(target)
    excludes = get_excludes(tracking_worktree_path, days=7, max_failures=5)
    if crate in excludes:
        print(f"Skipping {crate} as it has failed too many times recently")
        return False

    print(f"Checking {crate} {requested_version} for {target}")
    repo_url = get_repo_url()
    version = get_current_version_if_unbuilt(
        repo_url=repo_url,
        crate=crate,
        target=target,
        requested_version=requested_version,
    )
    if not version:
        return False

    no_default_features = "false"
    if crate == "gitoxide":
        features = "max-pure"
        no_default_features = "true"
    elif crate == "sccache":
        features = "vendored-openssl"
    else:
        features = ",".join(
            feat
            for feat in version["features"].keys()
            if "vendored" in feat or "bundled" in feat
        )
    build_os = get_build_os(target)
    branch = get_branch()
    workflow_run_input = {
        "crate": crate,
        "version": version["vers"],
        "target": target,
        "features": features,
        "no_default_features": no_default_features,
        "build_os": build_os,
        "branch": branch,
    }
    print(f"Attempting to build {crate} {version['vers']} for {target}")
    subprocess.run(
        ["gh", "workflow", "run", "build-package.yml", "--json", f"--ref={branch}"],
        input=json.dumps(workflow_run_input).encode(),
        check=True,
    )
    return True


@lru_cache
def get_excludes(tracking_worktree_path: str, days: int, max_failures: int) -> set[str]:
    """
    if a crate has reached `max_failures` failures in the last `days` days then we exclude it
    """
    failures = Counter()

    failure_filenames = list(Path(tracking_worktree_path).glob("*-*-*"))
    failure_filenames.sort(reverse=True)

    for failure_filename in failure_filenames[:days]:
        with open(failure_filename, "r") as file:
            failures.update(
                Counter(stripped for line in file if (stripped := line.strip()))
            )

    return set(crate for crate, count in failures.items() if count >= max_failures)


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
    target: str,
    requested_version: str | None = None,
) -> CrateVersionDict | None:
    # FIXME(probably never): in theory we could skip a round-trip to crates.io if we already know the version,
    # but the code ends up looking ugly so I decided not to bother.
    version = get_latest_version(crate, requested_version)
    if not version:
        return None

    url = f"{repo_url}/releases/download/{crate}-{version['vers']}/{crate}-{version['vers']}-{target}.tar.gz"
    response = requests.head(url, allow_redirects=True)
    if response.ok:
        print(f"{url} already uploaded")
        return None
    # FIXME: handle rate limit errors?

    return version


if __name__ == "__main__":
    main()
