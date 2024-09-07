from __future__ import annotations

import os

from influxdb_client_3 import InfluxDBClient3

TOKEN = os.environ.get("INFLUXDB_TOKEN")
ORG = "cargo-bins"
HOST = "https://us-east-1-1.aws.cloud2.influxdata.com"
DATABASE = "cargo-quickinstall"


def get_stats(period: str, arch: str | None):
    client = InfluxDBClient3(host=HOST, token=TOKEN, org=ORG, database=DATABASE)

    query = """
        SELECT DISTINCT crate
        FROM "counts"
        WHERE
            time >= now() - $period::interval and time <= now()
            and $arch is null or arch = $arch
    """

    # FIXME: pyarrow.Table doesn't have types: https://github.com/apache/arrow/issues/32609
    table = client.query(
        query=query,
        language="sql",
        query_parameters={
            "period": period,
            "arch": arch,
        },
    )

    return table


def get_requested_crates(period: str, arch: str | None) -> list[str]:
    table = get_stats(period=period, arch=arch)
    return [str(crate) for crate in table["crate"]]


if __name__ == "__main__":
    table = get_stats(period="1 day", arch=None)
    for crate in table["crate"]:
        print(crate)
