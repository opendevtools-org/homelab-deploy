#!/usr/bin/env python3
"""CVE CLI — nested JAR scan in Docker and fixed-CVE lookup from JSON sources."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict
from pathlib import Path

CLI_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CLI_ROOT / "lib"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from homelab_cli.color import color_text, colors_enabled  # noqa: E402
from homelab_cve.fixed import get_fixed_cves  # noqa: E402
from homelab_cve.jars import JarMatch  # noqa: E402
from homelab_cve.scan import check_jar_version  # noqa: E402
from homelab_cve.sources import load_cve_config  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="cve", description="Inspect JARs in a container and list fixed CVEs.")
    parser.add_argument(
        "--config",
        default=os.environ.get("HOMELAB_CVE_CONFIG"),
        help="JSON sources file (default: bundled example, or HOMELAB_CVE_CONFIG)",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    jar_parser = subparsers.add_parser("check-jar-version", help="Search nested JARs in a container")
    jar_parser.add_argument("--jar", required=True, help="Artifact name with or without .jar")
    jar_parser.add_argument("--container", required=True, help="Container name or ID")
    jar_parser.add_argument("--root", default=None, help="Scan root (default: config default_scan_root or /)")
    jar_parser.add_argument("--json", action="store_true", help="JSON output")
    jar_parser.add_argument("--no-color", action="store_true")

    fixed_parser = subparsers.add_parser("check-fixed-cve", help="List CVEs marked fixed for a library version")
    fixed_parser.add_argument("--library", required=True)
    fixed_parser.add_argument("--version", required=True)
    fixed_parser.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    config = load_cve_config(args.config)

    if args.command == "check-fixed-cve":
        try:
            cves = get_fixed_cves(args.library, args.version, config)
        except Exception as error:
            print(f"Error: {error}", file=sys.stderr)
            return 1
        if args.json:
            print(json.dumps([asdict(cve) for cve in cves], ensure_ascii=False, indent=2))
            return 0
        print(f"\n{args.library} {args.version}")
        print(f"Found {len(cves)} fixed CVEs:\n")
        for cve in cves:
            severity = cve.severity or "UNKNOWN"
            score = f" CVSS {cve.cvss_score}" if cve.cvss_score is not None else ""
            print(f" - {cve.cve} [{severity}]{score}")
        return 0

    enabled = colors_enabled(no_color=args.no_color)
    root = args.root or config.default_scan_root or "/"

    def on_match(match: JarMatch) -> None:
        location = f"{match.containing_jar}: {match.location}" if match.containing_jar else match.location
        print(
            f"  {color_text('found:', 'yellow', enabled)} {color_text(location, 'cyan', enabled)} -> "
            f"{color_text(match.version or 'version not found', 'green', enabled)}",
            file=sys.stderr,
            flush=True,
        )

    try:
        print(
            color_text(
                f"Scanning {args.container}:{root} for {os.path.basename(args.jar)}...",
                "bold",
                enabled,
            ),
            file=sys.stderr,
            flush=True,
        )
        matches = check_jar_version(args.container, args.jar, root, on_match=on_match)
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        detail = (
            error.stderr.decode(errors="replace").strip()
            if isinstance(error, subprocess.CalledProcessError)
            else "docker not found"
        )
        print(f"Docker error: {detail}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps([asdict(match) for match in matches], ensure_ascii=True, indent=2))
        return 0
    if not matches:
        print(f"No occurrences of {os.path.basename(args.jar)} found.")
        return 0

    grouped: dict[str, list[JarMatch]] = {}
    for match in matches:
        grouped.setdefault(match.version or "version not found", []).append(match)
    print(
        color_text(
            f"Found {len(matches)} occurrences of {os.path.basename(args.jar)} in {len(grouped)} versions:",
            "bold",
            enabled,
        )
    )
    for version, version_matches in grouped.items():
        print(f"\n{color_text(f'Version {version} ({len(version_matches)} hits):', 'blue', enabled)}")
        for match in version_matches:
            location = (
                f"{match.containing_jar}!{match.location}" if match.containing_jar else match.location
            )
            source = f" [{match.version_source}]" if match.version_source else ""
            print(f"  - {color_text(location, 'cyan', enabled)}{source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
