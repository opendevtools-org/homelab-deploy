from __future__ import annotations

from pathlib import Path


def dotenv_value(path: str | Path, key: str) -> str | None:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    prefix = f"{key}="
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#") or not stripped.startswith(prefix):
            continue
        return stripped[len(prefix) :].strip().strip("'\"") or None
    return None
