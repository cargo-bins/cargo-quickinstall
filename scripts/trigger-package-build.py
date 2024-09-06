#!/usr/bin/env python

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

from scripts.get_latest_version import CrateVersionDict, get_latest_version
from scripts.checkout_worktree import checkout_worktree_for_arch
from scripts.stats import get_requested_crates


def main():
    """
    TODO:
    - [ ] next-unbuilt-package.sh
    - [ ] get-stats.sh + popular-crates.txt | dedup-and-exclude.py | shuf -n 5
        - [x] get-stats.sh
        - [x] I think we should pull the logic from print-build-excludes.sh into python-land, and also do the worktree nonsense as needed.
    - [ ] filter_already_built_crates:
        - [x] curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" (or use the sparse index api with no rate limit?)
        - [x] curl_slowly --location --fail -I --output "${REPO}/releases/download/${CRATE}-${VERSION}/${CRATE}-${VERSION}-${TARGET_ARCH}.tar.gz"
    - [ ] take the result and feed it through the logic from trigger-build-package-workflow.py:
        line = "{\"crate\": \"$CRATE\", \"version\": \"$VERSION\", \"target_arch\": \"$TARGET_ARCH\", \"features\": \"$FEATURES\", \"no_default_features\": \"$NO_DEFAULT_FEATURES\"}"
                | jq --unbuffered -c ". + {build_os: \"$BUILD_OS\" , branch: \"$BRANCH\"}"
        subprocess.run(("gh", "workflow", "run", "build-package.yml", "--json"), input=line.encode(), check=True)
        time.sleep(30)
    """
    target_arch = get_target_arch()
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

    repo_url = get_repo_url()
    branch = get_branch()
    builds_scheduled = 0
    for crate in crates_to_check:
        version = get_next_unbuilt_version(
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
            ["gh", "workflow", "run", "build-package.yml", "--json"],
            input=json.dumps(workflow_run_input).encode(),
            check=True,
        )
        builds_scheduled += 1
        if builds_scheduled >= check_limit:
            print("Scheduled enough builds, exiting", file=sys.stderr)
            break
        time.sleep(30)


def get_build_os(target_arch: str) -> str:
    # FIXME: use a dict for this?
    if target_arch == "x86_64-apple-darwin":
        return "macos-latest"
    elif target_arch == "aarch64-apple-darwin":
        return "macos-latest"
    elif target_arch == "x86_64-unknown-linux-gnu":
        return "ubuntu-20.04"
    elif target_arch == "x86_64-unknown-linux-musl":
        return "ubuntu-20.04"
    elif target_arch == "x86_64-pc-windows-msvc":
        return "windows-latest"
    elif target_arch == "aarch64-pc-windows-msvc":
        return "windows-latest"
    elif target_arch == "aarch64-unknown-linux-gnu":
        return "ubuntu-20.04"
    elif target_arch == "aarch64-unknown-linux-musl":
        return "ubuntu-20.04"
    elif target_arch == "armv7-unknown-linux-musleabihf":
        return "ubuntu-20.04"
    elif target_arch == "armv7-unknown-linux-gnueabihf":
        return "ubuntu-20.04"
    else:
        raise ValueError(f"Unrecognised target arch: {target_arch}")


def get_target_arch():
    target_arch = os.environ.get("TARGET_ARCH", None)
    if target_arch:
        return target_arch

    rustc_version_output = subprocess.run(
        ["rustc", "--version", "--verbose"], capture_output=True, text=True
    )

    # Extract the 'host' line using a Python equivalent of sed
    for line in rustc_version_output.stdout.splitlines():
        if line.startswith("host: "):
            return line.split("host: ")[1]
    else:
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
    repo_var = os.environ.get("GITHUB_REPOSITORY")
    if repo_var:
        return f"https://github.com/{GITHUB_REPOSITORY}"
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


def get_next_unbuilt_version(
    repo_url: str,
    crate: str,
    target_arch: str,
) -> CrateVersionDict | None:
    try:
        version = get_latest_version(crate)
    except:
        print(f"Failed to get latest version for {crate}", file=sys.stderr)
        return None

    url = f"{repo_url}/releases/download/{crate}-{version['vers']}/{crate}-{version['vers']}-{target_arch}.tar.gz"
    response = requests.head(url, allow_redirects=True)
    if response.ok:
        print(f"{url} already uploaded", file=sys.stderr)
        return None
    # FIXME: handle rate limit errors?

    return version


if __name__ == "__main__":
    main()
