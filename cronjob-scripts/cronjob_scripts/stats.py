from __future__ import annotations

from polars import DataFrame

from functools import lru_cache
import os

from influxdb_client_3 import InfluxDBClient3

from cronjob_scripts.types import CrateAndVersion

TOKEN = os.environ.get("INFLUXDB_TOKEN")
ORG = "cargo-bins"
HOST = "https://us-east-1-1.aws.cloud2.influxdata.com"
DATABASE = "cargo-quickinstall"

_influxdb_client = None


@lru_cache
def get_stats(period: str) -> DataFrame:
    """
    To reduce the number of round-trips to the InfluxDB server, we do a single query and cache the
    results of this function.

    In theory it would be better if we could use a dataloader-like pattern to batch up requests and
    ask for exactly the architectures we want, but that would require us to make the whole script
    async, and we know that cronjob will eventually ask for all architectures anyway.
    """
    global _influxdb_client
    if _influxdb_client is None:
        _influxdb_client = InfluxDBClient3(
            host=HOST, token=TOKEN, org=ORG, database=DATABASE
        )

    # Old clients (going via the old stats server) don't report status, so we filter them out.
    # FIXME: seems like there are some entries of the form:
    # {"agent": "binstalk-fetchers/0.10.0", "status": "start", ... }
    # All I can think of is that they are from some external user of the binstalk-fetchers crate
    # in someone's CI, and it's not been updated with the current approach to reporting stats?
    query = """
        SELECT DISTINCT crate, target, version
        FROM "counts"
        WHERE
            time >= now() - $period::interval and time <= now()
            and status is not null and status not in ('start', 'installed-from-tarball')
    """

    table = _influxdb_client.query(
        query=query,
        language="sql",
        query_parameters={
            "period": period,
        },
        mode="polars",
    )

    print(table)
    return table


def get_requested_crates(period: str, target: str | None) -> list[CrateAndVersion]:
    df = get_stats(period=period)

    if target is not None:
        # for now, if target in influxdb is null then build for all targets
        # (just until we have a day's worth of data with `target` set)
        mask = (df["target"] == target) | df["target"].is_null()

        df = df.filter(mask)

    return df[["crate", "version"]].to_dicts()
