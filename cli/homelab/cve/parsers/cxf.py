"""Apache CXF security advisories."""

from __future__ import annotations

from urllib.parse import urljoin

import re
from urllib.parse import urljoin

from markup import html_links, page_text
from net import fetch_text
from ..models import CVE_RE, CveHit, LibrarySource, unique_by_cve
from ..nvd import attach_nvd

RANGE_RE = re.compile(
    r"Apache CXF \(([^)]+)\)\s+(?:(\S+)\s+)?before\s+(\S+)",
    re.IGNORECASE,
)


def _advisory_urls(html: str, base_url: str, cve_id: str | None = None) -> list[str]:
    urls: list[str] = []
    for href, text in html_links(html):
        blob = f"{href} {text}".upper()
        if "CVE-" not in blob:
            continue
        if cve_id and cve_id.upper() not in blob:
            continue
        urls.append(urljoin(base_url, href))
    if cve_id and not urls:
        urls.append(urljoin(base_url, f"security-advisories.data/{cve_id}.txt?version=1&api=v2"))
    return list(dict.fromkeys(urls))


def _ranges_from_text(text: str) -> list[tuple[str, str, str]]:
    return RANGE_RE.findall(text)


def search_cxf(cve_id: str, source: LibrarySource) -> CveHit | None:
    cve_id = cve_id.upper()
    index = fetch_text(source.cves_url)
    urls = _advisory_urls(index, source.cves_url, cve_id)
    if not urls:
        return None
    advisory_url = urls[0]
    try:
        text = page_text(fetch_text(advisory_url))
    except Exception:
        return None
    ranges = _ranges_from_text(text)
    module = ranges[0][0] if ranges else None
    affected = "; ".join(f"{start or '*'} before {fixed}" for _, start, fixed in ranges) or None
    fixed_in = ", ".join(fixed for _, _, fixed in ranges) or None
    return attach_nvd(
        CveHit(
            cve=cve_id,
            source="cxf",
            url=advisory_url,
            module=module,
            affected=affected,
            fixed_in=fixed_in,
            release_notes_url=source.release_notes_url,
        )
    )


def get_cxf_fixed_cves(version: str, source: LibrarySource) -> list[CveHit]:
    wanted = version.strip()
    index = fetch_text(source.cves_url)
    results: list[CveHit] = []
    for url in _advisory_urls(index, source.cves_url):
        cves = CVE_RE.findall(url.upper()) or CVE_RE.findall(url)
        try:
            text = page_text(fetch_text(url))
        except Exception:
            continue
        ranges = _ranges_from_text(text)
        if not any(fixed == wanted for _, _, fixed in ranges):
            continue
        cve = (cves[0] if cves else None) or (CVE_RE.findall(text) or [None])[0]
        if not cve:
            continue
        if not str(cve).upper().startswith("CVE-"):
            cve = f"CVE-{cve}"
        results.append(
            attach_nvd(
                CveHit(
                    cve=cve,
                    source="cxf",
                    url=url,
                    fixed_in=wanted,
                    release_notes_url=source.release_notes_url,
                )
            )
        )
    return unique_by_cve(results)
