#!/usr/bin/env python3
"""PKM launcher: form JSON on stdin → homelab CVE CLI, output streamed live."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

CLI_ROOT = Path(os.environ.get("HOMELAB_CLI_ROOT", "/app/cli"))
sys.path.insert(0, str(CLI_ROOT / "lib"))
sys.path.insert(0, str(CLI_ROOT))
scriptkit = Path("/app/scriptkit")
if scriptkit.is_dir() and str(scriptkit) not in sys.path:
    sys.path.insert(0, str(scriptkit))

from homelab.cve.pkm_form import argv_from_form  # noqa: E402
from odt_scripts.process import stream  # noqa: E402


def main() -> int:
    raw = sys.stdin.read()
    try:
        params = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as exc:
        print(f"Invalid JSON on stdin: {exc}", file=sys.stderr)
        return 2
    if not isinstance(params, dict):
        print("stdin JSON must be an object", file=sys.stderr)
        return 2

    try:
        cve_argv = argv_from_form(params)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    env = os.environ.copy()
    extra = os.pathsep.join([str(CLI_ROOT / "lib"), str(CLI_ROOT)])
    previous = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = extra if not previous else extra + os.pathsep + previous
    env["PYTHONUNBUFFERED"] = "1"
    env.setdefault("HOMELAB_CLI_ROOT", str(CLI_ROOT))

    argv = [sys.executable, "-u", "-m", "homelab.cve", *cve_argv]
    sys.stdout.write("python -m homelab.cve " + " ".join(cve_argv) + "\n")
    sys.stdout.flush()
    return stream(argv, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
