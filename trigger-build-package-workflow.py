#!/usr/bin/env python3

# Replacement for xargs since it will automatically remove
# quotes unless it's gnu xargs, which supports `-d "\n"`.
#
# Using python is just way more readable and cross-platform.

import time
import subprocess
import sys


cmd = ("gh", "workflow", "run", "build-package.yml", "--json")

def main():
    for line in sys.stdin:
        line = line.strip() 

        if len(line) == 0:
            continue

        print("Trigger workflow with json", line, file=sys.stderr)
        subprocess.run(cmd, input=line.encode(), check=True)
        time.sleep(30)

if __name__ == "__main__":
    main()
