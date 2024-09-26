#!/usr/bin/env python3

from cronjob_scripts.stats import get_requested_crates, get_stats

if __name__ == "__main__":
    # FIXME(probably never): this should probably be moved into the tests/ directory instead
    from cronjob_scripts.targets import TARGET_TO_BUILD_OS

    for target in TARGET_TO_BUILD_OS.keys():
        print(f"{target}: {len(get_requested_crates(period='1 day', target=target))}")

    table = get_stats(period="1 day")
    print(f"total {len(table)}")
