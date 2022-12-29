#!/usr/bin/env python3

import datetime
import json
import os
from urllib.request import urlopen
import typing


def fetch_one_day_of_stats(day: datetime.date) -> typing.Dict[str, int]:
    here = os.path.dirname(os.path.realpath(__file__))
    filename = f"{here}/raw/{day.isoformat()}.json"

    if not os.path.exists(filename):
        print(f"fetching {filename}")
        resp = urlopen(f"https://warehouse-clerk-tmp.vercel.app/api/stats?year={day.year}&month={day.month}&day={day.day}")
        bytes = resp.read()
        with open(filename, 'wb') as f:
            f.write(bytes)

    with open(filename) as f:
        return json.load(f)


def fetch_all_stats():
    # Don't get today's data because it might still be being written.
    # Also don't get yesterday, because we might be in a timezone
    # that is ahead of UTC, so it might still be being written.
    day = datetime.date.today() - datetime.timedelta(days=2)

    # We switched from monthly to daily on datetime.date(2022, 7, 30)
    # but this will do for now: don't want to blast through our upstash
    # quotas in one go.
    while day >= datetime.date(2022, 9, 1):
        stats = fetch_one_day_of_stats(day)
        assert stats, "stats dict should not be empty"
        day -= datetime.timedelta(days=1)


if __name__ == "__main__":
    fetch_all_stats()
