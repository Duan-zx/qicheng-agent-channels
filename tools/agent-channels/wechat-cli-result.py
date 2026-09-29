#!/usr/bin/env python3
"""Fail closed on WeChat CLI error output even when Electron exits zero."""
import json
import re
import sys


def failed(output):
    for line in output.splitlines():
        if re.search(r"\[error\]", line, re.I):
            return True
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if isinstance(data, dict) and "code" in data and data["code"] not in (0, "0"):
            return True
    return False


if __name__ == "__main__":
    sys.exit(1 if failed(sys.stdin.read()) else 0)
