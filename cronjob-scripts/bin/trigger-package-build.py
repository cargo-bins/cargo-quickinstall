#!/usr/bin/env python3

import sys

from cronjob_scripts.trigger_package_build import main


if __name__ == "__main__":
    if len(sys.argv) > 1:
        print(
            "Usage: INFLUXDB_TOKEN= target= CRATE_CHECK_LIMIT= RECHECK= GITHUB_REPOSITORY= trigger-package-build.py"
        )
        if sys.argv[1] == "--help":
            exit(0)
        exit(1)
    main()
