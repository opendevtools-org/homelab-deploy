#!/usr/bin/env python3
"""Example site CLI: echo stdin JSON or --input-json."""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Product library is on PYTHONPATH (/app/scriptkit) inside the PKM container.
from odt_scripts.cli import Cli
from odt_scripts.jsonio import read_json_stdin


def _payload_from_args(args) -> dict:
    if getattr(args, "input_json", None):
        text = Path(args.input_json).read_text(encoding="utf-8")
        return read_json_stdin(text)
    return read_json_stdin()


def echo(args) -> int:
    payload = _payload_from_args(args)
    json.dump({"echo": payload}, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


def build_app() -> Cli:
    app = Cli(prog="echo-cli", description="Echo JSON from PKM stdin or --input-json")
    echo_parser = app.add_command("echo", echo, help="Print the form payload")
    echo_parser.add_argument("--input-json", default="")
    return app


if __name__ == "__main__":
    raise SystemExit(build_app().main())
