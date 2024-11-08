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

    # Old clients (going via the old stats server) don't report status, so we will end up triggering
    # re-checks even for things successfully installed from tarball. Hopefully these will gradually
    # get phased out and then this method will only return crate versions which ended up installing
    # from source.
    #
    # FIXME: seems like there are some entries of the form:
    # {"agent": "binstalk-fetchers/0.10.0", "status": "start", ... }
    # Apparently binswap-github is using an old version of binstalk. See:
    # https://github.com/cargo-bins/cargo-quickinstall/pull/300/files#r1778063083
    query = """
        SELECT DISTINCT crate, target, version
        FROM "counts"
        WHERE
            time >= now() - $period::interval and time <= now()
            and (status is null or status not in ('start', 'installed-from-tarball'))
    """

    table: DataFrame = _influxdb_client.query(  # type: ignore
        query=query,
        language="sql",
        query_parameters={
            "period": period,
        },
        mode="polars",
    )

    return table


def get_requested_crates(period: str, target: str | None) -> list[CrateAndVersion]:
    df = get_stats(period=period)

    if target is not None:
        df = df.filter(df["target"] == target)

    return df[["crate", "version"]].to_dicts()  # type: ignore


def main():
    table = get_stats(period="1 day")
    for crate in table["crate"].unique():
        print(crate)


if __name__ == "__main__":
    # Warning: it's best to use .venv/bin/stats rather than calling this directly, to avoid
    # sys.modules ending up with this dir at the front, shadowing stdlib modules.
    main()
