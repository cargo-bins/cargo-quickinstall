#!/usr/bin/env python3

import sys
import subprocess
import json


def gh_api(args):
    result = subprocess.run(["gh", "api"] + args, capture_output=True, text=True)
    result.check_returncode()
    return result.stdout


def git_push_tags(tags):
    if tags:
        print(f"Pushing tags: {' '.join(tags)}")
        subprocess.run(["git", "push", "origin"] + tags, check=True)


def undraft_release(repo, release_id):
    print(f"Undrafting release ID: {release_id}")
    result = subprocess.run(
        [
            "gh",
            "api",
            "-X",
            "PATCH",
            f"/repos/{repo}/releases/{release_id}",
            "-f",
            "draft=false",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Error undrafting release ID {release_id}:\n{result.stdout}\n{result.stderr}"
        )


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} owner/repo [page]")
        sys.exit(1)
    repo = sys.argv[1]
    page = sys.argv[2] if len(sys.argv) > 2 else "1"

    releases_json = gh_api([f"/repos/{repo}/releases?per_page=100&page={page}"])
    releases = json.loads(releases_json)

    tag_names = [r["tag_name"] for r in releases]
    draft_ids = [r["id"] for r in releases if r.get("draft")]

    print(f"Releases on page {page} of {repo}:")
    print("Tag Name | Draft | Release Name")
    print("----------------------------------------")
    for r in releases:
        print(f"{r['tag_name']} | {r['draft']} | {r.get('name', '')}")

    confirm = input("\nProceed to undelete (push tags and undraft releases)? [y/N] ")
    if confirm.lower() != "y":
        print("Aborted.")
        sys.exit(0)

    git_push_tags(tag_names)
    for rid in draft_ids:
        undraft_release(repo, rid)


if __name__ == "__main__":
    main()
