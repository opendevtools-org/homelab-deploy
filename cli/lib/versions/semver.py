from __future__ import annotations

import re

_VERSION = re.compile(r"v?(\d+(?:\.\d+)+)")


def version_tuple(version: str) -> tuple[int, ...] | None:
    match = _VERSION.fullmatch(version.strip())
    if match is None:
        match = _VERSION.search(version.strip())
        if match is None:
            return None
    parts = [int(part) for part in match.group(1).split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def cmp_versions(left: str, right: str) -> int | None:
    a = version_tuple(left)
    b = version_tuple(right)
    if a is None or b is None:
        return None
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def in_half_open(current: str, lower: str, upper: str) -> bool:
    """True if lower <= current < upper."""
    cur = version_tuple(current)
    lo = version_tuple(lower)
    hi = version_tuple(upper)
    if cur is None or lo is None or hi is None:
        return False
    return lo <= cur < hi


def in_closed(current: str, lower: str, upper: str) -> bool:
    """True if lower <= current <= upper."""
    cur = version_tuple(current)
    lo = version_tuple(lower)
    hi = version_tuple(upper)
    if cur is None or lo is None or hi is None:
        return False
    return lo <= cur <= hi
