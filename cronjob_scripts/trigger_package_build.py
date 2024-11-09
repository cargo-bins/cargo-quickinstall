#!/usr/bin/env python

from __future__ import annotations


from collections import Counter
from functools import lru_cache
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import time
from typing import cast

from cronjob_scripts.types import CrateAndMaybeVersion, CrateAndVersion, GithubAsset
from cronjob_scripts.architectures import get_build_os, get_target_architectures
from cronjob_scripts.checkout_worktree import checkout_worktree_for_target
from cronjob_scripts.get_latest_version import CrateVersionDict, get_latest_version
from cronjob_scripts.stats import get_requested_crates
from cronjob_scripts.crates_io_popular_crates import get_crates_io_popular_crates

MAX_CHECKS_PER_QUEUE = 1000


def main():
    """
    Triggers a package build in a vaguely fair way.

    General approach:
    * construct the following list of crates (n lists for each target):
        * for each target:
            * TODO (probably never): the list of install requests with the "built-from-source" or
              "not-found" status in the last day (ordered by popularity, including versions.
              WARNING: this is very likely to result in the same crate being built many times in
              parallel if someone runs the cronjob manually on ci/locally)
            * the list of install requests with the "built-from-source" or
              "not-found" status in the last day (shuffled, including versions)
            * the list of install requests with any other status in the last day (shuffled, with
              versions stripped)
            * popular-crates.txt (shuffled)
            * a list with just cargo-quickinstall and nothing else (if doing the weekly recheck job)
    * shuffle the list of lists and then round-robin between each list:
        * take the head of the list
        * if we already checked this package for this target, skip it
        * if we already tried to build this package 5 times in the last 7 days, skip it
          (TODO: also record the version in the failure log?)
        * check its latest version + if we have a package built for it. If we don't have a package
          built for it, trigger a build
            * if we already triggered m package builds since the start of the run, exit (probably
              set this to n times the number of targets?)
    * if we hit a github rate limit when doing this, this is fine and we just bomb out having made some progress?
    * if we get to the end without triggering any builds then that's fine too: there's nothing to do.

    Shuffling the lists means that:
    * we will at least make some progress fairly on all architectures even if something goes wrong or we hit rate limits
    * we don't need to track any state to avoid head-of-line blocking (the "trigger/*" branches used
      to track where we got to for each target for fairness, but shuffled builds are simpler)
    """
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
        tracking_worktree_path = checkout_worktree_for_target(target)
        excluded = get_excluded(tracking_worktree_path, days=7, max_failures=5)

        # This should be a small list of crates, so we should get around to checking everything here
        # pretty often. This doesn't include failures from old clients (via the old stats server)
        # because they don't report status.
        failed = get_requested_crates(
            period="1 day", target=target, statuses=["built-from-source", "not-found"]
        )
        failed = without_excluded(failed, excluded)
        random.shuffle(failed)
        queues.append(("failed", target, failed))

        # This will be a large list of crates, so it might take a while to get around to checking
        # everything here.
        all_requested = get_requested_crates(period="1 day", target=target)
        all_requested = without_excluded(all_requested, excluded)
        random.shuffle(all_requested)
        queues.append(("requested", target, all_requested))

        # This is also large, and will take a while to check.
        queues.append(("popular", target, without_excluded(popular_crates, excluded)))

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
    for index in range(MAX_CHECKS_PER_QUEUE):
        for type, target, all_requested in queues:
            triggered = trigger_for_target(type, target, all_requested, index)
            time.sleep(1)
            if triggered:
                triggered_count += 1
                if triggered_count > 2 * len(targets):
                    print(f"Triggered enough builds {triggered_count}, exiting")
                    return
    print(
        f"Checked {MAX_CHECKS_PER_QUEUE} per queue and only triggered {triggered_count} builds, exiting"
    )


def trigger_for_target(
    type: str, target: str, queue: list[CrateAndMaybeVersion], index: int
) -> bool:
    if len(queue) <= index:
        return False
    crate_and_maybe_version = queue[index]
    print(f"Triggering {type} build for {target}: {crate_and_maybe_version}")
    crate = crate_and_maybe_version["crate"]
    requested_version = crate_and_maybe_version.get("version")

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
        "target_arch": target,
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


def without_excluded(
    queue: list[CrateAndMaybeVersion] | list[CrateAndVersion], excluded: set[str]
) -> list[CrateAndMaybeVersion]:
    return [c for c in queue if c["crate"] not in excluded]  # type: ignore - sneaky downcast


@lru_cache
def get_excluded(tracking_worktree_path: str, days: int, max_failures: int) -> set[str]:
    """
    if a crate has reached `max_failures` failures in the last `days` days then we exclude it
    """
    failures: Counter[str] = Counter()

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

    tag = f"{crate}-{version['vers']}"
    tarball = f"{crate}-{version['vers']}-{target}.tar.gz"

    if any(asset["name"] == tarball for asset in get_assets_for_tag(tag)):
        print(f"{tarball} already uploaded")
        return None

    return version


@lru_cache
def get_assets_for_tag(tag: str) -> list[GithubAsset]:
    try:
        out = subprocess.check_output(
            ["gh", "release", "view", tag, "--json=assets"],
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as e:
        if b"release not found" in e.stderr:
            return []
        print(e.stderr, file=sys.stderr)
        raise
    parsed = json.loads(out)
    return parsed["assets"]


if __name__ == "__main__":
    main()
