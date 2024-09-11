from __future__ import annotations

import subprocess
import tarfile
from tempfile import TemporaryDirectory
from shutil import copyfileobj

import requests
import polars as pl

class TarEntry:
    def __init__(self, tarball: tarfile.TarFile, member: tarfile.TarInfo):
        self.tarball = tarball
        self.member = member

    def is_one_of_csvs_interested(self, csvs_to_extract: tuple[str, ...]) -> str | None:
        if not self.member.isfile():
            return None
        for name in csvs_to_extract:
            if self.member.name.endswith(f"data/{name}"):
                return name
        return None

    def extract_to(self, path: str):
        with open(path, mode="xb") as f:
            stream = self.tarball.extractfile(self.member)
            assert stream
            copyfileobj(stream, f)

def download_tar_gz(url):
    response = requests.get(url, stream=True)
    response.raise_for_status()

    with tarfile.open(fileobj=response.raw, mode='r:gz') as tarball:
        while True:
            member = tarball.next()
            if member is None:
                return
            yield TarEntry(tarball, member)

def get_crates_io_popular_crates(minimum_downloads=4000):
    with TemporaryDirectory() as temp_dir:
        files_to_extract = ("crate_downloads.csv", "crates.csv", "default_versions.csv", "versions.csv")
        files_extracted = 0
        for entry in download_tar_gz('https://static.crates.io/db-dump.tar.gz'):
            name = entry.is_one_of_csvs_interested(files_to_extract)
            if name:
                entry.extract_to(f"{temp_dir}/{name}")
                files_extracted += 1
                if files_extracted == len(files_to_extract):
                    break

        return (
            row[0]
            for row in pl.scan_csv(f"{temp_dir}/crate_downloads.csv")
            .join(pl.scan_csv(f"{temp_dir}/crates.csv").select("id", "name"), left_on="crate_id", right_on="id")
            .join(pl.scan_csv(f"{temp_dir}/default_versions.csv"), on="crate_id")
            .join(
                pl.scan_csv(f"{temp_dir}/versions.csv").select("id", "crate_id", "yanked", "bin_names"),
                left_on=("crate_id", "version_id"),
                right_on=("crate_id", "id"),
            )
            .filter(pl.col("bin_names") != "{}", pl.col("yanked") == "f")
            .filter(pl.col("downloads") > 40000)
            .select("name")
            # TODO: https://github.com/pola-rs/polars/issues/10683
            .collect(streaming=True)
            .iter_rows()
        )


if __name__ == "__main__":
    import sys

    if len(sys.argv) == 2 and sys.argv[1] in ('-h', '--help'):
        print(f"Usage: {sys.argv[0]} (minimum_downloads)")
        sys.exit(1)

    if len(sys.argv) > 1:
        minimum_downloads = int(sys.argv[1])
    else:
        minimum_downloads = 4000
    print(list(get_crates_io_popular_crates(minimum_downloads)))
