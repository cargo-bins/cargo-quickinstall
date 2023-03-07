#!/usr/bin/env python3

import sys

def strip_whitespace(iterable):
    for s in iterable:
        s = s.strip()
        if len(s) != 0:
            yield s

def stderr(s):
    print(s, file=sys.stderr, flush=True)

if len(sys.argv) == 3:
    with open(sys.argv[1]) as f:
        s = set(strip_whitespace(f))
    max_lines = int(sys.argv[2])
else:
    program = sys.argv[0]
    stderr(f"Usage: {program}: /path/to/excludes max-num-of-lines-to-output")
    sys.exit(1)

dup = set()
cnt = 0

for line in sys.stdin:
    line = line.strip()

    if line in s:
        stderr(f"skipping {line} because it has failed too many times")
    elif len(line) != 0 and line not in dup:
        print(line)
        dup.add(line)
        cnt += 1
        if cnt == max_lines:
            break
