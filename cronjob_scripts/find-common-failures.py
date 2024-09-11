from __future__ import annotations

import json
import os
import subprocess
from typing import TypedDict

import polars as pl


def cache_on_disk_json(func):
    def wrapper(*args, **kwargs):
        cache_file = f"/tmp/{func.__name__}/{args}-{kwargs}.json"
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
            print(f"WARNING: Failed to decode {cache_file}. Deleting.")
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
    print(run for run in runs if ("status" not in run))
    return [
        run
        for run in runs
        if run["status"] == "completed" and run["conclusion"] == "failure"
    ]


@cache_on_disk_polars
def get_logs(databaseId: WorkflowRun["databaseId"]) -> pl.DataFrame:
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
    return logs.filter(
        logs["message"].str.starts_with("error: ")
        # | logs["message"].str.starts_with("warning: ")
    ).unique()


def main():
    pl.Config.set_fmt_str_lengths(1000).set_tbl_rows(1000)
    failing_runs = get_failing_runs(limit=100)
    print(failing_runs)
    print("failing run count:", len(failing_runs))

    all_errors = None
    for run in failing_runs:
        logs = get_logs(run["databaseId"])
        logs = tidy_logs(logs)

        errors = get_unique_errors(logs)
        if errors.shape[0] == 0:
            print(
                "WARNING: No errors found in logs, even though the run failed:",
                run["url"],
            )
        all_errors = errors if all_errors is None else all_errors.extend(errors)

    print(all_errors["message"].value_counts(sort=True))
    # print(all_errors)


if __name__ == "__main__":
    main()
