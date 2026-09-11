"""Read the first non-empty environment variable from a list of names."""

from __future__ import annotations

import os


def first_env(*names: str, default: str = "") -> str:
    for name in names:
        value = (os.environ.get(name) or "").strip()
        if value:
            return value
    return default
