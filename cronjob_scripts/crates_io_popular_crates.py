from __future__ import annotations

import tarfile
import warnings
from pathlib import Path
from typing import TypedDict

import requests
import polars as pl

from cronjob_scripts.types import CrateAndMaybeVersion

warnings.filterwarnings("ignore", message="Polars found a filename")


class TarEntry:
    def __init__(self, tarball: tarfile.TarFile, member: tarfile.TarInfo):
        self.tarball = tarball
        self.member = member

    def is_one_of_csvs_interested(self, csvs_to_extract: list[str]) -> str | None:
        if not self.member.isfile():
            return None
        for name in csvs_to_extract:
            if self.member.name.endswith(f"data/{name}"):
                return name
        return None

    def get_file_stream(self):
        stream = self.tarball.extractfile(self.member)
        assert stream
        return stream


def download_tar_gz(url):
    response = requests.get(url, stream=True)
    response.raise_for_status()

    with tarfile.open(fileobj=response.raw, mode="r:gz") as tarball:
        for member in tarball:
            yield TarEntry(tarball, member)


class Dfs(TypedDict):
    crate_downloads: pl.LazyFrame
    crates: pl.LazyFrame
    default_versions: pl.LazyFrame
    versions: pl.LazyFrame


def get_dfs() -> Dfs:
    files_to_extract = [
        "crate_downloads.csv",
        "crates.csv",
        "default_versions.csv",
        "versions.csv",
    ]
    files_extracted = 0
    dfs = {}
    for entry in download_tar_gz("https://static.crates.io/db-dump.tar.gz"):
        name = entry.is_one_of_csvs_interested(files_to_extract)
        if name:
            dfs[name[:-4]] = pl.scan_csv(entry.get_file_stream())
            files_extracted += 1
            if files_extracted == len(files_to_extract):
                return Dfs(**dfs)

    raise RuntimeError(f"Failed to find all csvs {files_to_extract}")


def get_crates_io_popular_crates_inner(minimum_downloads=200000):
    dfs = get_dfs()
    return (
        dfs["crate_downloads"]
        .join(dfs["crates"].select("id", "name"), left_on="crate_id", right_on="id")
        .join(dfs["default_versions"], on="crate_id")
        .join(
            dfs["versions"].select("id", "crate_id", "yanked", "bin_names"),
            left_on=("crate_id", "version_id"),
            right_on=("crate_id", "id"),
        )
        .filter(pl.col("bin_names") != "{}", pl.col("yanked") == "f")
        .filter(pl.col("downloads") > minimum_downloads)
        .select("name")
    )


def get_crates_io_popular_crates(
    minimum_downloads: int = 200000,
) -> list[CrateAndMaybeVersion]:
    cached_path = Path("cached_crates_io_popular_crates.parquet")
    if cached_path.is_file():
        # TODO: Once `iter_rows()` can be used on LazyFrame, use it for better perf
        #  and less ram usage.
        # https://github.com/pola-rs/polars/issues/10683
        df = pl.read_parquet(cached_path)
    else:
        df = (
            get_crates_io_popular_crates_inner(minimum_downloads)
            # TODO: Use streaming, maybe use sink_parquet instead?
            # https://github.com/pola-rs/polars/issues/18684
            .collect()
        )
        df.write_parquet(cached_path, statistics=False)

    df = df.rename({"name": "crate"})
    return df.to_dicts()


def main():
    import sys

    if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
        print(f"Usage: {sys.argv[0]} (minimum_downloads)")
        sys.exit(1)

    if len(sys.argv) > 1:
        minimum_downloads = int(sys.argv[1])
    else:
        minimum_downloads = 200000
    print(list(get_crates_io_popular_crates(minimum_downloads)))


if __name__ == "__main__":
    # Warning: it's best to use .venv/bin/crates-io-popular-crates rather than calling this directly, to avoid
    # sys.modules ending up with this dir at the front, shadowing stdlib modules.
    main()
