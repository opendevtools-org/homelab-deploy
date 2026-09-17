from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import asdict, is_dataclass


def dump_json(items: Iterable[object]) -> None:
    payload = [asdict(item) if is_dataclass(item) and not isinstance(item, type) else item for item in items]
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def print_lookup(rows) -> None:
    for row in rows:
        print(f"{row.cve} [{row.source}] {row.url}")
        if row.fixed_in:
            print(f"  fixed_in: {row.fixed_in}")
        if row.affected:
            print(f"  affected: {row.affected}")
        if row.release_notes_url:
            print(f"  release_notes: {row.release_notes_url}")
        if row.description:
            print(f"  {row.description}")


def print_fixed(library: str, version: str, cves) -> None:
    print(f"\n{library} {version}")
    print(f"Found {len(cves)} fixed CVEs:\n")
    for cve in cves:
        severity = cve.severity or "UNKNOWN"
        score = f" CVSS {cve.cvss_score}" if cve.cvss_score is not None else ""
        print(f" - {cve.cve} [{severity}]{score}")
