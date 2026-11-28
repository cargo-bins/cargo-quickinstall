#!/usr/bin/env python

from __future__ import annotations

import json
import os
import random
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from cronjob_scripts.architectures import get_build_os, get_target_architectures
from cronjob_scripts.checkout_worktree import checkout_worktree_for_target
from cronjob_scripts.crates_io_popular_crates import get_crates_io_popular_crates
from cronjob_scripts.get_latest_version import CrateVersionDict, get_latest_version
from cronjob_scripts.stats import get_requested_crates
from cronjob_scripts.types import CrateAndMaybeVersion, CrateAndVersion, GithubAsset


MAX_CHECKS_PER_QUEUE = 1000
# GitHub runs the hourly schedule only a few times a day, so trigger enough
# builds per run to keep up with the install requests that missed. A run gets
# this many builds per target, and any target can use them.
MAX_TRIGGERS_PER_TARGET = 4
# The builds run offline in a fixed sandbox, so building a version that failed
# again fails the same way. Give up on a crate, whatever the version, after
# this many failures on a target in the last 7 days.
MAX_FAILURES = 2


@dataclass
class QueueInfo:
    type: str
    target: str
    queue: list[CrateAndMaybeVersion]
    # (crate, version) pairs that can never build for this target.
    unbuildable: frozenset[tuple[str, str]] = frozenset()


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
        * if we already tried to build this package MAX_FAILURES times in the last 7 days, skip it
          (TODO: also record the version in the failure log?)
        * if this version of the package failed on a compile error in its own source, skip it
          for good, see get_unbuildable()
        * check its latest version + if we have a package built for it. If we don't have a package
          built for it, and this run did not already trigger this version for this target, trigger
          a build
            * if we already triggered MAX_TRIGGERS_PER_TARGET times the number of targets package
              builds since the start of the run, exit
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
            sys.exit(0)
        sys.exit(1)

    targets = get_target_architectures()
    queues: list[QueueInfo] = []

    recheck_crate = os.environ.get("RECHECK_ONLY")
    popular_crates: list[CrateAndMaybeVersion] = []
    if not recheck_crate:
        # we shuffle the list of popular crates from crates.io once, and use it for every arch, to slightly
        # reduce the number of requests we need to make to crates.io. It probably isn't worth it though.
        popular_crates = get_crates_io_popular_crates()
        random.shuffle(popular_crates)

    for target in targets:
        if recheck_crate:
            queues.append(
                QueueInfo(
                    type="recheck",
                    target=target,
                    queue=[CrateAndMaybeVersion(crate=recheck_crate, version=None)],
                )
            )
            continue

        tracking_worktree_path = checkout_worktree_for_target(target)
        excluded = get_excluded(
            tracking_worktree_path, days=7, max_failures=MAX_FAILURES
        )
        unbuildable = get_unbuildable(tracking_worktree_path)

        # This should be a small list of crates, so we should get around to checking everything here
        # pretty often. This doesn't include failures from old clients (via the old stats server)
        # because they don't report status.
        failed = get_requested_crates(
            period="1 day", target=target, statuses=["built-from-source", "not-found"]
        )
        failed = without_excluded(failed, excluded)
        random.shuffle(failed)
        queues.append(
            QueueInfo(
                type="failed", target=target, queue=failed, unbuildable=unbuildable
            )
        )

        # This will be a large list of crates, so it might take a while to get around to checking
        # everything here.
        all_requested = get_requested_crates(period="1 day", target=target)
        all_requested = without_excluded(all_requested, excluded)
        random.shuffle(all_requested)
        queues.append(
            QueueInfo(
                type="requested",
                target=target,
                queue=all_requested,
                unbuildable=unbuildable,
            )
        )

        # This is also large, and will take a while to check.
        queues.append(
            QueueInfo(
                type="popular",
                target=target,
                queue=without_excluded(popular_crates, excluded),
                unbuildable=unbuildable,
            )
        )

    print("Queues:")
    for queue in queues:
        print(f"{queue.target} {queue.type}: {len(queue.queue)} items")
    random.shuffle(queues)

    max_index = min(max(len(q.queue) for q in queues), MAX_CHECKS_PER_QUEUE)
    max_triggers = MAX_TRIGGERS_PER_TARGET * len(targets)
    print(
        f"Checking {max_index} crates per queue ({len(queues)} queues), to trigger at most {max_triggers} builds"
    )
    # The queues of a target overlap: "requested" has everything in "failed".
    triggered: set[tuple[str, str, str]] = set()
    for index in range(max_index + 1):
        for queue in queues:
            trigger_for_target(queue, index, triggered)
            time.sleep(1)
            if len(triggered) >= max_triggers:
                print(f"Triggered enough builds ({len(triggered)}), exiting")
                return
    print(
        f"Checked {max_index} crates per queue ({len(queues)} queues) and triggered {len(triggered)} builds, exiting"
    )


def trigger_for_target(
    queue: QueueInfo, index: int, triggered: set[tuple[str, str, str]]
) -> None:
    """
    Triggers a build of the crate at `index` in `queue` unless it needs none, or
    this run already triggered it, and adds what it triggered to `triggered`.
    """
    if len(queue.queue) <= index:
        return
    crate_and_maybe_version = queue.queue[index]
    print(
        f"Checking build for {queue.target} '{queue.type}': {crate_and_maybe_version}"
    )
    crate = crate_and_maybe_version["crate"]
    requested_version = crate_and_maybe_version.get("version")

    # Crate names come from install reports that anyone can send, and end up
    # in URLs, workflow inputs and shell scripts.
    if not is_valid_crate_name(crate):
        print(f"Skipping invalid crate name {crate!r}")
        return

    print(f"Checking {crate} {requested_version} for {queue.target}")
    repo_url = get_repo_url()
    version = get_current_version_if_unbuilt(
        repo_url=repo_url,
        crate=crate,
        target=queue.target,
        requested_version=requested_version,
        unbuildable=queue.unbuildable,
    )
    if not version:
        return

    build = (crate, version["vers"], queue.target)
    if build in triggered:
        print(f"Already triggered {crate} {version['vers']} for {queue.target}")
        return

    no_default_features = "false"
    if crate == "gitoxide":
        features = "max-pure"
        no_default_features = "true"
    elif crate == "sccache":
        features = "vendored-openssl"
    else:
        features = ",".join(
            feat
            for feat in version["features"]
            if "vendored" in feat or "bundled" in feat
        )
    build_os = get_build_os(queue.target)
    branch = get_branch()
    workflow_run_input = {
        "crate": crate,
        "version": version["vers"],
        "target_arch": queue.target,
        "features": features,
        "no_default_features": no_default_features,
        "build_os": build_os,
        "branch": branch,
    }
    print(f"Triggering build of {crate} {version['vers']} for {queue.target}")
    # The cronjob on main sets BUILD_PACKAGE_REF=builds, see build-package.yml.
    # Elsewhere, such as when testing a branch, dispatch on the branch itself.
    dispatch_ref = os.environ.get("BUILD_PACKAGE_REF") or branch
    subprocess.run(
        [
            "gh",
            "workflow",
            "run",
            "build-package.yml",
            "--json",
            f"--ref={dispatch_ref}",
        ],
        input=json.dumps(workflow_run_input).encode(),
        check=True,
    )
    triggered.add(build)


# crates.io only allows ASCII alphanumerics, `-` and `_`, at most 64 characters.
CRATE_NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")


def is_valid_crate_name(crate: str) -> bool:
    return CRATE_NAME_RE.fullmatch(crate) is not None


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

    return {crate for crate, count in failures.items() if count >= max_failures}


@lru_cache
def get_unbuildable(tracking_worktree_path: str) -> frozenset[tuple[str, str]]:
    """
    The (crate, version) pairs in the `unbuildable` file, one "crate version" per line, which
    add-exclude.sh appends to when a build failed on a compile error in the crate's own source
    (see root_crate_error.py). Building that version again would fail the same way, but a new
    version gets built as usual.
    """
    try:
        with open(Path(tracking_worktree_path) / "unbuildable", "r") as file:
            return frozenset(
                (fields[0], fields[1])
                for line in file
                if len(fields := line.split()) == 2
            )
    except FileNotFoundError:
        return frozenset()


@lru_cache
def get_repo_url() -> str:
    repo_env_var = os.environ.get("GITHUB_REPOSITORY")
    if repo_env_var:
        return f"https://github.com/{repo_env_var}"
    return subprocess.run(
        ["gh", "repo", "view", "--json", "url", "--jq", ".url"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def get_branch() -> str:
    return subprocess.run(
        ["git", "branch", "--show-current"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


def get_current_version_if_unbuilt(
    repo_url: str,
    crate: str,
    target: str,
    requested_version: str | None = None,
    unbuildable: frozenset[tuple[str, str]] = frozenset(),
) -> CrateVersionDict | None:
    # FIXME(probably never): in theory we could skip a round-trip to crates.io if we already know the version,
    # but the code ends up looking ugly so I decided not to bother.
    version = get_latest_version(crate, requested_version)
    if not version:
        return None

    if (crate, version["vers"]) in unbuildable:
        print(f"{crate} {version['vers']} does not compile for {target}")
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
