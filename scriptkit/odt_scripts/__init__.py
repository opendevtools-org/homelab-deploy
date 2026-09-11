"""Helpers for site CLIs and PKM script launchers.

Site tools live under ``cli/<name>/``. PKM launchers live under
``data/pkm/scripts/<name>/``. This package is product code: Update-HomelabUpstream
refreshes it. Do not put site-specific commands here.
"""

from .cli import Cli
from .env import first_env
from .git import clone_or_update
from .jsonio import read_json_stdin, write_temp_json
from .launcher import run_cli_from_stdin
from .process import RunResult, run

__all__ = [
    "Cli",
    "RunResult",
    "clone_or_update",
    "first_env",
    "read_json_stdin",
    "run",
    "run_cli_from_stdin",
    "write_temp_json",
]
