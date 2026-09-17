"""Parse https://curl.se/docs/security.html (CVE table + first/last affected)."""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urljoin

from markup import iter_rows
from net import fetch_text
from ..models import CVE_RE, CveHit, LibrarySource, unique_by, unique_by_cve
from ..nvd import attach_nvd

VERSION_HREF = re.compile(r"vuln-([0-9][0-9A-Za-z.+-]*)\.html", re.IGNORECASE)


@dataclass
class CurlAdvisory:
    cve: str
    title: str | None
    published: str | None
    first_affected: str | None
    last_affected: str | None
    advisory_url: str | None


def _row_to_advisory(cells: list[str], hrefs: list[str], base_url: str) -> CurlAdvisory | None:
    blob = " ".join(cells)
    match = CVE_RE.search(blob)
    if not match:
        return None
    cve = match.group(0)
    title = None
    for text in cells:
        if cve in text:
            rest = text.split(":", 1)
            if len(rest) == 2:
                title = rest[1].strip()
            break
    versions = []
    for href in hrefs:
        found = VERSION_HREF.search(href or "")
        if found:
            versions.append(found.group(1))
    first_affected = versions[0] if versions else None
    last_affected = versions[1] if len(versions) > 1 else (versions[0] if versions else None)
    published = None
    for text in cells:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            published = text
            break
    advisory_href = next(
        (href for href in hrefs if href and cve in href.upper().replace(".HTML", "")),
        "",
    )
    if not advisory_href:
        advisory_href = f"{cve}.html"
    return CurlAdvisory(
        cve=cve,
        title=title,
        published=published,
        first_affected=first_affected,
        last_affected=last_affected,
        advisory_url=urljoin(base_url, advisory_href),
    )


def parse_curl_advisories(html: str, base_url: str) -> list[CurlAdvisory]:
    rows = [
        advisory
        for row in iter_rows(html)
        if (advisory := _row_to_advisory(row.cells, row.hrefs, base_url))
    ]
    unique = unique_by(rows, lambda item: item.cve)
    if unique:
        return unique
    return _parse_curl_fallback(html, base_url)


def _parse_curl_fallback(html: str, base_url: str) -> list[CurlAdvisory]:
    results: list[CurlAdvisory] = []
    for match in re.finditer(
        r"(CVE-\d{4}-\d+)(?:\.html)?(?::\s*([^<\n\]]+))?",
        html,
        re.IGNORECASE,
    ):
        window = html[match.start() : match.start() + 400]
        versions = VERSION_HREF.findall(window)
        published_match = re.search(r"(\d{4}-\d{2}-\d{2})", window)
        href_match = re.search(rf"{re.escape(match.group(1))}\.html", window, re.IGNORECASE)
        advisory_href = href_match.group(0) if href_match else f"{match.group(1)}.html"
        results.append(
            CurlAdvisory(
                cve=match.group(1),
                title=(match.group(2) or "").strip() or None,
                published=published_match.group(1) if published_match else None,
                first_affected=versions[0] if versions else None,
                last_affected=versions[1] if len(versions) > 1 else (versions[0] if versions else None),
                advisory_url=urljoin(base_url, advisory_href),
            )
        )
    return unique_by(results, lambda item: item.cve)


def _hit_from_advisory(advisory: CurlAdvisory, source: LibrarySource) -> CveHit:
    affected = None
    if advisory.first_affected and advisory.last_affected:
        affected = f"{advisory.first_affected} .. {advisory.last_affected}"
    hit = CveHit(
        cve=advisory.cve,
        source="curl",
        url=advisory.advisory_url or source.cves_url,
        module="curl/libcurl",
        affected=affected,
        fixed_in=advisory.last_affected,
        description=advisory.title,
        release_notes_url=source.release_notes_url,
    )
    return attach_nvd(hit)


def get_curl_fixed_cves(version: str, source: LibrarySource) -> list[CveHit]:
    html = fetch_text(source.cves_url)
    wanted = version.strip()
    hits = [
        _hit_from_advisory(advisory, source)
        for advisory in parse_curl_advisories(html, source.cves_url)
        if advisory.last_affected == wanted
    ]
    return unique_by_cve(hits)


def search_curl(cve_id: str, source: LibrarySource) -> CveHit | None:
    html = fetch_text(source.cves_url)
    cve_id = cve_id.upper()
    for advisory in parse_curl_advisories(html, source.cves_url):
        if advisory.cve.upper() == cve_id:
            return _hit_from_advisory(advisory, source)
    return None
