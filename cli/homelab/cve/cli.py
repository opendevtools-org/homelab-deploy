#!/usr/bin/env python3
"""CVE CLI — nested JAR scan in Docker and fixed-CVE lookup from JSON sources."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from term import color_text, colors_enabled

from .fixed import LookupOnlyError, get_fixed_cves
from .ids import normalize_cve_ids
from .inventory import compare_cves_against_inventory, inventory_dependencies
from .lookup import lookup_cve
from .models import JarMatch
from .output import dump_json, print_fixed, print_lookup
from .scan import check_jar_version
from .sources import load_cve_config


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

    lookup_parser = subparsers.add_parser("lookup-cve", help="Find CVEs on vendor advisory sources")
    lookup_parser.add_argument(
        "--cve",
        nargs="+",
        required=True,
        help="One or more CVE/GO ids (spaces or commas)",
    )
    lookup_parser.add_argument("--source", default=None, help="Limit to a library name or provider")
    lookup_parser.add_argument("--inventory", default=None, help="Optional dependency inventory JSON")
    lookup_parser.add_argument("--json", action="store_true")

    compare_parser = subparsers.add_parser("compare-inventory", help="Classify CVEs against a dependency inventory")
    compare_parser.add_argument("--inventory", required=True)
    compare_parser.add_argument("--cve", nargs="+", required=True)
    compare_parser.add_argument("--source", default=None)
    compare_parser.add_argument("--json", action="store_true")

    args = parser.parse_args(argv)
    config = load_cve_config(args.config)

    if args.command in {"lookup-cve", "compare-inventory"}:
        cve_ids = normalize_cve_ids(args.cve)
        if not cve_ids:
            parser.error("no valid CVE ID (expected CVE-YYYY-n or GO-YYYY-n)")
        try:
            rows = []
            for cve_id in cve_ids:
                rows.extend(lookup_cve(cve_id, config, source=args.source))
        except Exception as error:
            print(f"Error: {error}", file=sys.stderr)
            return 1

        inventory_path = getattr(args, "inventory", None)
        comparison = None
        if inventory_path or args.command == "compare-inventory":
            if not inventory_path:
                parser.error("compare-inventory requires --inventory")
            try:
                inventory_data = json.loads(Path(inventory_path).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                print(f"Inventory error: {error}", file=sys.stderr)
                return 1
            inventory = inventory_dependencies(inventory_data)
            if inventory is None:
                print("Inventory JSON must be a list or an object with dependencies.", file=sys.stderr)
                return 1
            comparison = compare_cves_against_inventory(inventory, rows)

        if args.json:
            dump_json(comparison if comparison is not None else rows)
            return 0
        if comparison is not None:
            if not comparison:
                print(f"No advisory match for {', '.join(cve_ids)}")
                return 0
            for item in comparison:
                print(f"{item['cve']} [{item['status']}] {item['module']} {item.get('artifact_version') or ''}".rstrip())
            return 0
        if not rows:
            print(f"No advisory match for {', '.join(cve_ids)}")
            return 0
        print_lookup(rows)
        return 0

    if args.command == "check-fixed-cve":
        try:
            cves = get_fixed_cves(args.library, args.version, config)
        except LookupOnlyError as error:
            print(f"Error: {error}", file=sys.stderr)
            return 2
        except Exception as error:
            print(f"Error: {error}", file=sys.stderr)
            return 1
        if args.json:
            dump_json(cves)
            return 0
        print_fixed(args.library, args.version, cves)
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
        dump_json(matches)
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
