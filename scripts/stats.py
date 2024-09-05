import os

from influxdb_client_3 import InfluxDBClient3

TOKEN = os.environ.get("INFLUXDB_TOKEN")
ORG = "cargo-bins"
HOST = "https://us-east-1-1.aws.cloud2.influxdata.com"
DATABASE = "cargo-quickinstall"


def get_stats():
    client = InfluxDBClient3(host=HOST, token=TOKEN, org=ORG, database=DATABASE)

    query = """
        SELECT crate
        FROM "counts"
        WHERE time >= now() - interval '1 day' and time <= now()
        GROUP BY crate
        ORDER BY crate
    """

    # FIXME: pyarrow.Table doesn't have types: https://github.com/apache/arrow/issues/32609
    table = client.query(query=query, language="sql")

    return table


if __name__ == "__main__":
    table = get_stats()
    for crate in table["crate"]:
        print(crate)
