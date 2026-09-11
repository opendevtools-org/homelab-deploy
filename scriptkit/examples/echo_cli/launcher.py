#!/usr/bin/env python3
"""PKM launcher example: forward the form JSON to echo-cli."""

from __future__ import annotations

import sys
from pathlib import Path

from odt_scripts.launcher import run_cli_from_stdin

CLI = Path(__file__).resolve().parent / "main.py"


def main() -> int:
    return run_cli_from_stdin([sys.executable, str(CLI), "echo"])


if __name__ == "__main__":
    raise SystemExit(main())
