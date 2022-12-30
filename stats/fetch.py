#!/usr/bin/env python3

import datetime
import json
import os
import subprocess
import typing

class DownloadRecord(typing.TypedDict):
    day: str
    package: str
    version: str
    arch: str
    count: int


class FullRecord(DownloadRecord):
    build_date: str | None


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


def tidy_stats(day: datetime.date, stats: typing.Dict[str, int]) -> typing.Iterable[DownloadRecord]:
    for k, count in stats.items():
        (package, version, arch) = k.split("/")

        yield {
            "date": day.isoformat(),
            "package": package,
            "version": version,
            "arch": arch,
            "count": count
        }

_build_date_cache = {}

def get_build_date(record: DownloadRecord) -> str | None:
    tag = f'{record["package"]}-{record["version"]}-{record["arch"]}'
    if tag in _build_date_cache:
        return _build_date_cache[tag]

    try:
        build_date = subprocess.check_output([
            "git",
            "show",
            "--quiet",
            "--pretty=%cd",  # committer date
            "--date=short",
            tag,
        ], stderr=subprocess.DEVNULL).strip().decode()
    except subprocess.CalledProcessError:
        build_date = None

    _build_date_cache[tag] = build_date
    return build_date


def add_build_date(record: DownloadRecord) -> FullRecord:
    build_date = get_build_date(record)
    return dict(**record, build_date=build_date)


def fetch_all_records() -> typing.Iterable[DownloadRecord]:
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
        for record in tidy_stats(day, stats):
            yield add_build_date(record)
        day += datetime.timedelta(days=1)


def write_tidied_records():
    here = os.path.dirname(os.path.realpath(__file__))
    filename = f"{here}/tidy.jsonl"
    with open(filename, 'w') as f:
        for stat in fetch_all_records():
            json.dump(stat, f)
            f.write('\n')


if __name__ == "__main__":
    write_tidied_records()
