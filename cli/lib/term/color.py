from __future__ import annotations

import os
import sys

COLORS = {
    "cyan": "\033[36m",
    "green": "\033[32m",
    "yellow": "\033[33m",
    "blue": "\033[34m",
    "bold": "\033[1m",
    "reset": "\033[0m",
}


def colors_enabled(*, no_color: bool = False) -> bool:
    if no_color or "NO_COLOR" in os.environ:
        return False
    return sys.stdout.isatty() or sys.stderr.isatty()


def color_text(text: str, name: str, enabled: bool) -> str:
    if not enabled:
        return text
    return f"{COLORS[name]}{text}{COLORS['reset']}"
