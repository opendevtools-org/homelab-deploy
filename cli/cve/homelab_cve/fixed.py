from __future__ import annotations

import re
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.request import urlopen

from .nvd import get_cve_details
from .sources import CveConfig, LibrarySource


@dataclass
class FixedCVE:
    cve: str
    fixed_in: str
    severity: str | None = None
    cvss_score: float | None = None
    description: str | None = None


CVE_RE = re.compile(r"CVE-\d{4}-\d+")


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.chunks: list[str] = []

    def handle_data(self, data: str) -> None:
        self.chunks.append(data)


def _page_text(html: str) -> str:
    parser = _TextExtractor()
    parser.feed(html)
    return "\n".join(parser.chunks)


def get_openssl_fixed_cves(version: str, url: str) -> list[FixedCVE]:
    with urlopen(url, timeout=30) as response:
        html = response.read().decode("utf-8", errors="replace")
    version_regex = re.compile(rf"\b{re.escape(version)}\b", re.IGNORECASE)
    results: list[FixedCVE] = []
    for chunk in _page_text(html).split("CVE-"):
        block = "CVE-" + chunk
        if not version_regex.search(block):
            continue
        for cve in CVE_RE.findall(block):
            severity, score = get_cve_details(cve)
            results.append(
                FixedCVE(cve=cve, fixed_in=version, severity=severity, cvss_score=score)
            )
    unique: dict[str, FixedCVE] = {}
    for item in results:
        unique[item.cve] = item
    return list(unique.values())


def get_fixed_cves(library: str, version: str, config: CveConfig) -> list[FixedCVE]:
    key = library.lower()
    source: LibrarySource | None = config.libraries.get(key)
    if source is None:
        raise ValueError(
            f"Library not in config: {library}. Known: {', '.join(sorted(config.libraries)) or '(none)'}"
        )
    if source.provider == "openssl":
        return get_openssl_fixed_cves(version, source.url)
    raise ValueError(f"Unsupported provider '{source.provider}' for library {library}")
