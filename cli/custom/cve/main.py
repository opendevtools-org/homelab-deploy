#!/usr/bin/env python3
"""Site CVE wrapper: product CLI plus optional local sources.json."""

from __future__ import annotations

import os
import sys
from pathlib import Path

CLI_ROOT = Path(__file__).resolve().parents[2]
CUSTOM_CVE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CLI_ROOT / "lib"))
sys.path.insert(0, str(CLI_ROOT))

from homelab.cve.cli import main as product_main  # noqa: E402


def main() -> int:
    argv = list(sys.argv[1:])
    local_config = CUSTOM_CVE / "config" / "sources.json"
    if "--config" not in argv and "-h" not in argv and "--help" not in argv:
        config = os.environ.get("HOMELAB_CVE_CONFIG")
        if not config and local_config.is_file():
            config = str(local_config)
        if config:
            argv = ["--config", config, *argv]
    return product_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
