#!/usr/bin/env python3

import datetime
import json
import os
import subprocess
import typing


class DownloadStats(typing.TypedDict):
    day: str
    package: str
    version: str
    arch: str
    count: int


def fetch_one_day_of_stats(day: datetime.date) -> typing.Dict[str, int]:
    here = os.path.dirname(os.path.realpath(__file__))
    filename = f"{here}/raw/{day.isoformat()}.json"

    if not os.path.exists(filename):
        print(f"fetching {filename}")
        subprocess.check_call([
            "curl",
            "--location",
            "--fail",
            f"https://warehouse-clerk-tmp.vercel.app/api/stats?year={day.year}&month={day.month}&day={day.day}",
            "--output",
            filename,
        ])

    with open(filename) as f:
        return json.load(f)


def tidy_stats(day: datetime.date, stats: typing.Dict[str, int]) -> typing.Iterable[DownloadStats]:
    for k, count in stats.items():
        (package, version, arch) = k.split("/")

        yield {
            "date": day.isoformat(),
            "package": package,
            "version": version,
            "arch": arch,
            "count": count
        }


def fetch_all_stats() -> typing.Iterable[DownloadStats]:
    # We switched from monthly to daily on datetime.date(2022, 7, 30)
    # but this will do for now: don't want to blast through our upstash
    # quotas in one go.
    earliest = datetime.date(2022, 9, 1)
    # Don't get today's data because it might still be being written.
    # Also don't get yesterday, because we might be in a timezone
    # that is ahead of UTC, so it might still be being written.
    latest = datetime.date.today() - datetime.timedelta(days=2)

    day = earliest
    while day <= latest:
        stats = fetch_one_day_of_stats(day)
        assert stats, "stats dict should not be empty"
        yield from tidy_stats(day, stats)
        day += datetime.timedelta(days=1)


def write_tidied_stats():
    here = os.path.dirname(os.path.realpath(__file__))
    filename = f"{here}/tidy.jsonl"
    with open(filename, 'w') as f:
        for stat in fetch_all_stats():
            json.dump(stat, f)
            f.write('\n')


if __name__ == "__main__":
    write_tidied_stats()
