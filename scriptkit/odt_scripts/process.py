"""Run a subprocess and return stdout/stderr/exit without raising on non-zero."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence


@dataclass(frozen=True)
class RunResult:
    stdout: str
    stderr: str
    returncode: int


def run(
    argv: Sequence[str],
    *,
    cwd: str | Path | None = None,
    env: Mapping[str, str] | None = None,
    input_text: str | None = None,
) -> RunResult:
    completed = subprocess.run(
        list(argv),
        cwd=str(cwd) if cwd is not None else None,
        env=dict(env) if env is not None else None,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )
    return RunResult(
        stdout=completed.stdout or "",
        stderr=completed.stderr or "",
        returncode=int(completed.returncode),
    )
