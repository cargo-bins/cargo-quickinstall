from cronjob_scripts.crates_io_popular_crates import get_crates_io_popular_crates


if __name__ == "__main__":
    import sys

    if len(sys.argv) == 2 and sys.argv[1] in ("-h", "--help"):
        print(f"Usage: {sys.argv[0]} (minimum_downloads)")
        sys.exit(1)

    if len(sys.argv) > 1:
        minimum_downloads = int(sys.argv[1])
    else:
        minimum_downloads = 200000
    print(list(get_crates_io_popular_crates(minimum_downloads)))
