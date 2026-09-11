"""JSON stdin and temporary input files for PKM launchers."""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from typing import Any


def read_json_stdin(raw: str | None = None) -> dict[str, Any]:
    """Parse JSON from stdin (or ``raw``). Empty input is ``{}``. Invalid JSON exits 2."""
    text = sys.stdin.read() if raw is None else raw
    stripped = (text or "").strip()
    if not stripped:
        return {}
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError as exc:
        print(f"Invalid JSON on stdin: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    if not isinstance(payload, dict):
        print("stdin JSON must be an object", file=sys.stderr)
        raise SystemExit(2)
    return payload


def write_temp_json(payload: dict[str, Any], *, suffix: str = ".json") -> Path:
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        suffix=suffix,
        delete=False,
    )
    try:
        json.dump(payload, handle, ensure_ascii=False)
        handle.write("\n")
    finally:
        handle.close()
    return Path(handle.name)
