#!/usr/bin/env python3
"""Stdlib tests for the site CLI / PKM launcher library."""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from odt_scripts.cli import Cli
from odt_scripts.env import first_env
from odt_scripts.jsonio import read_json_stdin, write_temp_json
from odt_scripts.launcher import run_cli_from_stdin


class EnvTests(unittest.TestCase):
    def test_first_env_skips_empty(self) -> None:
        os.environ["ODT_TEST_A"] = ""
        os.environ["ODT_TEST_B"] = "ok"
        try:
            self.assertEqual(first_env("ODT_TEST_A", "ODT_TEST_B"), "ok")
        finally:
            os.environ.pop("ODT_TEST_A", None)
            os.environ.pop("ODT_TEST_B", None)


class JsonTests(unittest.TestCase):
    def test_empty_stdin_is_object(self) -> None:
        self.assertEqual(read_json_stdin(""), {})

    def test_rejects_array(self) -> None:
        with self.assertRaises(SystemExit) as ctx:
            read_json_stdin("[1]")
        self.assertEqual(ctx.exception.code, 2)

    def test_temp_file_roundtrip(self) -> None:
        path = write_temp_json({"a": 1})
        try:
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"a": 1})
        finally:
            path.unlink(missing_ok=True)


class CliAndLauncherTests(unittest.TestCase):
    def test_cli_dispatches_command(self) -> None:
        seen: list[str] = []
        app = Cli(prog="t")
        app.add_command("ping", lambda _args: seen.append("ping") or 0)
        self.assertEqual(app.main(["ping"]), 0)
        self.assertEqual(seen, ["ping"])

    def test_launcher_forwards_json_and_cleans_temp(self) -> None:
        import io
        from unittest.mock import patch

        example = ROOT / "examples" / "echo_cli" / "main.py"
        previous = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = str(ROOT) + (
            os.pathsep + previous if previous else ""
        )
        try:
            with patch("odt_scripts.launcher.read_json_stdin", return_value={"hello": "world"}):
                with patch("odt_scripts.launcher.sys.stdout", new_callable=io.StringIO) as out:
                    code = run_cli_from_stdin([sys.executable, str(example), "echo"])
        finally:
            if previous is None:
                os.environ.pop("PYTHONPATH", None)
            else:
                os.environ["PYTHONPATH"] = previous
        self.assertEqual(code, 0)
        payload = json.loads(out.getvalue())
        self.assertEqual(payload["echo"], {"hello": "world"})


if __name__ == "__main__":
    unittest.main()
