"""IBM Semeru runtimes security table."""

from __future__ import annotations

import re

from markup import parse_tables
from net import fetch_text
from ..models import CVE_RE, CveHit, LibrarySource, unique_by_cve
from ..nvd import attach_nvd

SEMERU_MODULE = "com.ibm.semeru:semeru-runtime"


def _java_major(version: str) -> str:
    match = re.match(r"(\d+)", version.strip())
    return match.group(1) if match else "21"


def _semeru_tables(html: str):
    return parse_tables(html)


def search_semeru(cve_id: str, source: LibrarySource, java_major: str = "21") -> CveHit | None:
    cve_id = cve_id.upper()
    html = fetch_text(source.cves_url)
    for table in _semeru_tables(html):
        if not table:
            continue
        headers = [cell.lower() for cell in table[0].cells]
        try:
            fix_index = headers.index(f"semeru {java_major} fix")
        except ValueError:
            continue
        for row in table[1:]:
            if not row.cells or cve_id not in row.cells[0].upper() or fix_index >= len(row.cells):
                continue
            fixed_in = row.cells[fix_index]
            if not fixed_in or fixed_in.upper() in {"N/A", "NA"}:
                return None
            return attach_nvd(
                CveHit(
                    cve=cve_id,
                    source="semeru",
                    url=source.cves_url,
                    module=SEMERU_MODULE,
                    affected=f"before {fixed_in}",
                    fixed_in=fixed_in,
                    release_notes_url=source.release_notes_url,
                )
            )
    return None


def get_semeru_fixed_cves(version: str, source: LibrarySource) -> list[CveHit]:
    wanted = version.strip()
    major = _java_major(wanted)
    html = fetch_text(source.cves_url)
    results: list[CveHit] = []
    for table in _semeru_tables(html):
        if not table:
            continue
        headers = [cell.lower() for cell in table[0].cells]
        try:
            fix_index = headers.index(f"semeru {major} fix")
        except ValueError:
            continue
        for row in table[1:]:
            if not row.cells or fix_index >= len(row.cells):
                continue
            if row.cells[fix_index] != wanted:
                continue
            match = CVE_RE.search(row.cells[0])
            if not match:
                continue
            cve = match.group(0)
            results.append(
                attach_nvd(
                    CveHit(
                        cve=cve,
                        source="semeru",
                        url=source.cves_url,
                        module=SEMERU_MODULE,
                        fixed_in=wanted,
                        release_notes_url=source.release_notes_url,
                    )
                )
            )
    return unique_by_cve(results)
