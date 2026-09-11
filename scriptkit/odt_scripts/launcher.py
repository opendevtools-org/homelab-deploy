"""PKM server-mode: stdin JSON -> temp file -> CLI -> forward streams and exit."""

from __future__ import annotations

import os
import sys
from typing import Sequence

from .jsonio import read_json_stdin, write_temp_json
from .process import run


def run_cli_from_stdin(
    cli_argv: Sequence[str],
    *,
    input_flag: str = "--input-json",
) -> int:
    """Read the PKM form JSON from stdin, invoke ``cli_argv``, print its output.

    The temporary JSON file is always deleted. Return the CLI exit code.
    """
    payload = read_json_stdin()
    temp_path = write_temp_json(payload)
    try:
        argv = list(cli_argv) + [input_flag, str(temp_path)]
        result = run(argv)
        if result.stdout:
            sys.stdout.write(result.stdout)
            if not result.stdout.endswith("\n"):
                sys.stdout.write("\n")
        if result.stderr:
            sys.stderr.write(result.stderr)
            if not result.stderr.endswith("\n"):
                sys.stderr.write("\n")
        return result.returncode
    finally:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
