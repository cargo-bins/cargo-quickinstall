#!/usr/bin/env python

from __future__ import annotations


from collections import Counter
import json
import os
from pathlib import Path
import random
import subprocess
import time

import requests

from cronjob_scripts.types import CrateAndMaybeVersion
from cronjob_scripts.targets import get_build_os, get_targets
from cronjob_scripts.checkout_worktree import checkout_worktree_for_arch
from cronjob_scripts.get_latest_version import CrateVersionDict, get_latest_version
from cronjob_scripts.stats import get_requested_crates
from cronjob_scripts.crates_io_popular_crates import get_crates_io_popular_crates


"""
* construct the following list of crates (n lists for each arch):
  * for each arch:
    * the list of install requests with the "built-from-source" status in the last day (ordered by popularity, including versions - WARNING: this is very likely to result in the same crate being built many times in parallel if someone runs the cronjob manually on ci/locally)
    * the list of install requests with the "built-from-source" status in the last day (shuffled, including versions)
    * the list of install requests with any other status in the last day (shuffled, with versions stripped)
    * popular-crates.txt (shuffled)
    * a list with just cargo-quickinstall and nothing else
* shuffle the list of lists and then round-robin between each list:
  * take the head of the list
  * if we already checked this package for this arch, skip it
  * if we already tried to build this package 5 times in the last 7 days, skip it (TODO: also record the version in the failure log?)
  * check its latest version + if we have a package built for it. If we don't have a package built for it, trigger a build
    * if we already triggered m package builds since the start of the run, exit (probably set this to n times the number of arches?)
* if we hit a github rate limit when doing this, this is fine and we just bomb out having made some progress?
* if we get to the end without triggering any builds then that's fine too: there's nothing to do.

"""


def main():
    targets = get_targets()
    queues: list[list[CrateAndMaybeVersion]] = []
    for target in targets:
        queue = queue_for_target(target)
        queues.append(queue)

    random.shuffle(queues)

    for target in targets:
        trigger_for_target(target)


def queue_for_target(target: str) -> list[CrateAndMaybeVersion]:
    pass


def trigger_for_target(target: str):
    print(f"Triggering builds for {target}")

    build_os = get_build_os(target)

    tracking_worktree_path = checkout_worktree_for_arch(target)
    excludes = get_excludes(tracking_worktree_path, days=7, max_failures=5)

    possible_crates = set(get_crates_io_popular_crates())
    possible_crates.update(get_requested_crates(period="1 day", arch=target))

    possible_crates = possible_crates - set(excludes)

    # check random crates up to a limit.
    check_limit = int(os.environ.get("CRATE_CHECK_LIMIT", 5))
    # Note that the old next-unbuilt-package.sh script actually checked the top 4 * CRATE_CHECK_LIMIT
    # crates from get-stats.sh + popular-crates.txt rather than shuffling the whole lot before checking.
    # The original script just looped through the whole list, but kept track of where it got to,
    # to avoid getting stuck on unbuildable crates.
    #
    # For now I'm trying to be roughly backwards compatible with the old script's numbers,
    # but I think that shuffling first is an important bugfix. Once we are using crates.io sparse
    # index api without rate-limits, we can think about checking more crates.
    crates_to_check = random.sample(list(possible_crates), 4 * check_limit)
    if os.environ.get("RECHECK"):
        crates_to_check = ["cargo-quickinstall"] + crates_to_check

    repo_url = get_repo_url()
    branch = get_branch()
    builds_scheduled = 0
    for crate in crates_to_check:
        print(f"Checking {crate} for {target}")
        version = get_current_version_if_unbuilt(
            repo_url=repo_url, crate=crate, target=target
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
                feat
                for feat in version["features"].keys()
                if "vendored" in feat or "bundled" in feat
            )

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
        builds_scheduled += 1
        if builds_scheduled >= check_limit:
            print("Scheduled enough builds, exiting")
            break
        time.sleep(30)


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
                Counter(stripped for line in file if (stripped := line.strip()))
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
    target: str,
) -> CrateVersionDict | None:
    version = get_latest_version(crate)
    if not version:
        return None

    url = f"{repo_url}/releases/download/{crate}-{version['vers']}/{crate}-{version['vers']}-{target}.tar.gz"
    response = requests.head(url, allow_redirects=True)
    if response.ok:
        print(f"{url} already uploaded")
        return None
    # FIXME: handle rate limit errors?

    return version
