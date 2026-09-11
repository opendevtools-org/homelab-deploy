"""Small argparse wrapper so each site CLI is a list of named commands."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable, Sequence

CommandHandler = Callable[[argparse.Namespace], int | None]


class Cli:
    def __init__(self, *, prog: str, description: str = "") -> None:
        self.parser = argparse.ArgumentParser(prog=prog, description=description)
        self._sub = self.parser.add_subparsers(dest="command", required=True)
        self._handlers: dict[str, CommandHandler] = {}

    def add_command(
        self,
        name: str,
        handler: CommandHandler,
        *,
        help: str = "",
    ) -> argparse.ArgumentParser:
        sub = self._sub.add_parser(name, help=help)
        sub.set_defaults(_odt_command=name)
        self._handlers[name] = handler
        return sub

    def main(self, argv: Sequence[str] | None = None) -> int:
        args = self.parser.parse_args(list(argv) if argv is not None else None)
        name = getattr(args, "_odt_command", None)
        if not name or name not in self._handlers:
            self.parser.print_help(sys.stderr)
            return 2
        result = self._handlers[name](args)
        return 0 if result is None else int(result)
