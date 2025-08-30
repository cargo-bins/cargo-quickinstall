#!/usr/bin/env python3

import sys
import subprocess
import json
import concurrent.futures
import re


def gh_api(query, variables=None):
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    if variables:
        for key, value in variables.items():
            args.extend(["-f", f"{key}={value}"])
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"gh api failed with code {result.returncode}:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
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


def process_page(repo, cursor=None):
    owner, name = repo.split("/")
    query = """
    query($owner: String!, $name: String!, $cursor: String) {
      repository(owner: $owner, name: $name) {
        releases(first: 100, after: $cursor, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes {
            id
            tagName
            name
            isDraft
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
    """
    variables = {"owner": owner, "name": name}
    if cursor:
        variables["cursor"] = cursor

    result = json.loads(gh_api(query, variables))
    releases = result["data"]["repository"]["releases"]["nodes"]
    page_info = result["data"]["repository"]["releases"]["pageInfo"]

    total = len(releases)
    drafts = len([r for r in releases if r["isDraft"]])
    numbered = len([r for r in releases if re.search(r"\d+$", r.get("name", ""))])
    
    # Filter for drafts and number suffix
    releases = [r for r in releases if r["isDraft"] and re.search(r"\d+$", r.get("name", ""))]
    
    print(f"\nProcessing releases from {repo} (cursor: {cursor or 'start'}):")
    print(f"Found {total} releases, {drafts} drafts, {numbered} with trailing numbers")
    print(f"Processing {len(releases)} releases that match both criteria")
    
    if releases:
        print("\nTag Name | Release Name")
        print("----------------------------------------")
        for r in releases:
            name = r.get("name", "")
            print(f"{r['tagName']} | {name}")

        tag_names = [r["tagName"] for r in releases]
        draft_ids = [r["id"] for r in releases]

        git_push_tags(tag_names)
        if draft_ids:
            with concurrent.futures.ThreadPoolExecutor() as executor:
                futures = [executor.submit(undraft_release, repo, rid) for rid in draft_ids]
                for future in concurrent.futures.as_completed(futures):
                    future.result()

    return page_info["hasNextPage"], page_info["endCursor"]


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} owner/repo")
        sys.exit(1)
    repo = sys.argv[1]

    state_file = f".{repo.replace('/', '_')}_cursor"
    try:
        with open(state_file) as f:
            cursor = f.read().strip()
            print(f"Resuming from cursor: {cursor}")
    except FileNotFoundError:
        cursor = None

    while True:
        has_next, cursor = process_page(repo, cursor)
        if cursor:
            with open(state_file, "w") as f:
                f.write(cursor)
        if not has_next:
            break


if __name__ == "__main__":
    main()
if __name__ == "__main__":
    main()
