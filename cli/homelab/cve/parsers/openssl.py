"""Parse OpenSSL vulnerability list: 'from X before Y' ranges."""

from __future__ import annotations

import re
from dataclasses import dataclass

from markup import page_text
from net import fetch_text
from ..models import CveHit, LibrarySource
from ..nvd import attach_nvd

RANGE_RE = re.compile(r"from\s+(\d+(?:\.\d+)+)\s+before\s+(\d+(?:\.\d+)+)", re.IGNORECASE)


@dataclass
class OpenSSLAdvisory:
    cve: str
    ranges: list[tuple[str, str]]
    url: str


def parse_openssl_advisories(html: str, page_url: str) -> list[OpenSSLAdvisory]:
    text = page_text(html)
    parts = re.split(r"(CVE-\d{4}-\d+)", text)
    results: list[OpenSSLAdvisory] = []
    for index in range(1, len(parts), 2):
        cve = parts[index]
        body = parts[index + 1] if index + 1 < len(parts) else ""
        ranges = RANGE_RE.findall(body[:4000])
        results.append(OpenSSLAdvisory(cve=cve, ranges=ranges, url=page_url))
    unique: dict[str, OpenSSLAdvisory] = {}
    for item in results:
        unique[item.cve] = item
    return list(unique.values())


def _hit(advisory: OpenSSLAdvisory, source: LibrarySource) -> CveHit:
    affected = "; ".join(f"{lower} before {upper}" for lower, upper in advisory.ranges) or None
    fixed_in = ", ".join(dict.fromkeys(upper for _lower, upper in advisory.ranges)) or None
    return attach_nvd(
        CveHit(
            cve=advisory.cve,
            source="openssl",
            url=source.cves_url,
            affected=affected,
            fixed_in=fixed_in,
            release_notes_url=source.release_notes_url,
        )
    )


def get_openssl_fixed_cves(version: str, source: LibrarySource) -> list[CveHit]:
    html = fetch_text(source.cves_url)
    wanted = version.strip()
    hits: list[CveHit] = []
    for advisory in parse_openssl_advisories(html, source.cves_url):
        matching = [upper for _lower, upper in advisory.ranges if upper == wanted]
        if not matching:
            continue
        hit = _hit(advisory, source)
        hit.fixed_in = matching[0]
        hits.append(hit)
    return hits


def search_openssl(cve_id: str, source: LibrarySource) -> CveHit | None:
    html = fetch_text(source.cves_url)
    cve_id = cve_id.upper()
    for advisory in parse_openssl_advisories(html, source.cves_url):
        if advisory.cve.upper() == cve_id:
            return _hit(advisory, source)
    return None
