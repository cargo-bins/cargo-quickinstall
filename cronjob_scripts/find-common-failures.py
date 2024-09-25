#!/usr/bin/env python
from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import TypedDict
import hashlib


import polars as pl


# FIXME: add a max_age parameter to this decorator or something (by reading the mtime of the file)?
def cache_on_disk_json(func):
    def wrapper(*args, **kwargs):
        # If the function's source code is updated, we should invalidate the cache.
        # In theory we could also hash all dependencies of the function by looking up each word of
        # source code in globals(), but that probably wouldn't be bullet-proof, and this is easy to
        # reason about.
        hasher = hashlib.sha256()
        hasher.update(func.__code__.co_code)
        impl_hash = hasher.hexdigest()

        cache_file = f"/tmp/{func.__name__}/{args}-{kwargs}-{impl_hash}.json"
        try:
            with open(cache_file) as f:
                result = json.load(f)
                if isinstance(result, str):
                    with open(cache_file + ".txt", "w") as f:
                        f.write(result.encode)
                return result
        except FileNotFoundError:
            pass
        except json.JSONDecodeError:
            print(f"WARNING: Failed to decode {cache_file}. Deleting.", file=sys.stderr)
            os.remove(cache_file)

        result = func(*args, **kwargs)
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        with open(cache_file, "w") as f:
            json.dump(result, f)
        return result

    return wrapper


def cache_on_disk_polars(func):
    def wrapper(*args, **kwargs):
        cache_file = f"/tmp/{func.__name__}/{args}-{kwargs}.parquet"
        try:
            # It might be possible to use scan_parquet here for added laziness
            return pl.read_parquet(cache_file)
        except FileNotFoundError:
            pass

        result = func(*args, **kwargs)
        assert isinstance(result, pl.DataFrame)

        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        result.write_parquet(cache_file)

        return result

    return wrapper


class WorkflowRun(TypedDict):
    attempt: int
    conclusion: str
    createdAt: str
    databaseId: str
    # displayTitle: str
    # event: str
    # headBranch: str
    # headSha: str
    # name: str
    # number: int
    # startedAt: str
    status: str
    # updatedAt: str
    url: str
    # workflowDatabaseId: int
    # workflowName: str


# FIXME: remove this cache when we're done with messing about?
@cache_on_disk_json
def get_runs(limit) -> list[WorkflowRun]:
    output = subprocess.run(
        [
            "gh",
            "run",
            "list",
            f"--limit={limit}",
            f"--json={','.join(WorkflowRun.__annotations__.keys())}",
        ],
        capture_output=True,
        check=True,
    )
    return json.loads(output.stdout)


def get_failing_runs(limit: int) -> list[WorkflowRun]:
    runs = get_runs(limit=limit)

    return [
        run
        for run in runs
        if run["status"] == "completed" and run["conclusion"] == "failure"
    ]


@cache_on_disk_polars
def get_logs(databaseId: str) -> pl.DataFrame:
    output = subprocess.run(
        ["gh", "run", "view", str(databaseId), "--log"],
        capture_output=True,
        check=True,
    )

    # e.g. build-popular-package-webdriver-install-0.3.2-aarch64-unknown-linux-musl-\tSet up job\t2024-09-11T09:00:33.2327586Z Current runner version: '2.319.1'
    result = pl.read_csv(
        output.stdout,
        separator="\t",
        has_header=False,
        schema=pl.Schema(
            {
                "job": pl.String,
                "step": pl.String,
                "timestamp_and_message": pl.String,
            }
        ),
        # FIXME: some log lines legitimately contain tabs. Can we include them in timestamp_and_message?
        truncate_ragged_lines=True,
    )
    return result


def tidy_logs(logs: pl.DataFrame) -> pl.DataFrame:
    # split timestamp_and_message into timestamp and message
    logs = logs.with_columns(
        logs["job"].str.replace("^build-popular-package-(.*)-$", "${1}").alias("job"),
        # in theory we could parse the timestamp, but I don't think we actually need it right now.
        # logs["timestamp_and_message"].str.replace(" .*", "").alias("timestamp"),
        logs["timestamp_and_message"]
        .str.replace("^[^ ]* ", "")
        .str.replace(
            "^error: failed to run custom build command for `(.*) v.*`$",
            "error: failed to run custom build command for `${1} <snipped version>`",
        )
        # rewrite some common errors that show up as a result of other errors in the same build
        .str.replace(
            "^error: could not compile `.*` \(bin .*\) due to .* previous error",
            "<ignore: ${0}>",
        )
        .str.replace(
            "^error: failed to compile `.*`, intermediate artifacts can be found at.*",
            "<ignore: ${0}>",
        )
        .str.replace(
            "^warning: build failed, waiting for other jobs to finish...",
            "<ignore: ${0}>",
        )
        .alias("message"),
    )
    logs.drop_in_place("timestamp_and_message")
    return logs


def get_unique_errors(logs: pl.DataFrame) -> pl.DataFrame:
    errors = logs.filter(logs["message"].str.starts_with("error: ")).unique()

    if errors.shape[0] > 0:
        return errors

    warnings = logs.filter(
        (
            logs["message"].str.starts_with("warning: ")
            & ~logs["message"].str.starts_with(
                "warning: no Cargo.lock file published in "
            )
            | logs["message"].str.contains(
                "failed to select a version for the requirement"
            )
        )
    ).unique()

    if warnings.shape[0] > 0:
        return warnings

    errors = logs.filter(logs["message"].str.contains("^error(\[E[0-9]*\])?: ")).head()
    return errors


def df_to_markdown(df: pl.DataFrame) -> str:
    """Quick and dirty ChatGPT implementation, because polars doesn't have a to_markdown method."""
    # Get column names
    headers = df.columns

    # Create the header row in markdown format
    header_row = "| " + " | ".join(headers) + " |"

    # Create the separator row
    separator_row = "| " + " | ".join(["---"] * len(headers)) + " |"

    # Create the data rows
    data_rows = ["| " + " | ".join(map(str, row)) + " |" for row in df.to_numpy()]

    # Combine all rows
    markdown_table = "\n".join([header_row, separator_row] + data_rows)

    return markdown_table


def main():
    pl.Config.set_fmt_str_lengths(1000).set_tbl_rows(1000)
    failing_runs = get_failing_runs(limit=100)
    print("failing run count:", len(failing_runs), file=sys.stderr)

    all_errors = None
    for run in failing_runs:
        logs = get_logs(run["databaseId"])
        logs = logs.with_columns(pl.lit(run["url"]).alias("url"))
        logs = tidy_logs(logs)

        errors = get_unique_errors(logs)
        if errors.shape[0] == 0:
            print(
                "WARNING: No errors found in logs, even though the run failed:",
                run["url"],
                file=sys.stderr,
            )
        all_errors = errors if all_errors is None else all_errors.extend(errors)

    result = (
        all_errors.group_by("message")
        .agg(
            [
                pl.len().alias("count"),
                pl.col("job").first().alias("example_job"),
                # Annoyingly, this gives you a link to the top level of the run, and you have to
                # click through to the job. I think that we could work at the job level by using
                # the github api, but I started using the gh cli, so I'll leave this as an exercise
                # for the reader.
                pl.col("url").first().alias("example_url"),
            ]
        )
        .sort("count", descending=True)
    )
    print(df_to_markdown(result))


if __name__ == "__main__":
    if len(sys.argv) > 1:
        # yeah, I should probably have done this as a jupyter notebook, but nevermind.
        print(
            f"""
            USAGE: {sys.argv[0]} > /tmp/fail.md && code /tmp/fail.

            Then use vscode's preview mode to view the result.
            """,
            file=sys.stderr,
        )
        exit(1)
    main()
