"""Kubernetes official CVE feed."""

from __future__ import annotations

import json
from urllib.parse import urljoin

from markup import iter_rows
from net import fetch_text
from ..models import CveHit, LibrarySource
from ..nvd import attach_nvd

CVE_RECORD_URL = "https://cveawg.mitre.org/api/cve/{}"
KUBERNETES_MODULE = "kubernetes/kubernetes"


def _kubernetes_module(cve_id: str) -> str:
    try:
        raw = fetch_text(CVE_RECORD_URL.format(cve_id))
        data = json.loads(raw)
        products = {
            item["product"].lower()
            for item in data.get("containers", {}).get("cna", {}).get("affected", [])
            if item.get("product")
        } - {"kubernetes"}
    except Exception:
        products = set()
    return f"kubernetes/{products.pop()}" if len(products) == 1 else KUBERNETES_MODULE


def search_kubernetes(cve_id: str, source: LibrarySource) -> CveHit | None:
    cve_id = cve_id.upper()
    html = fetch_text(source.cves_url)
    for row in iter_rows(html):
        if cve_id not in row.blob.upper():
            continue
        href = next((item for item in row.hrefs if item), "")
        issue_url = urljoin(source.cves_url, href) if href else source.cves_url
        module = _kubernetes_module(cve_id)
        status = "fixed" if "cve-status-fixed" in row.classes else "unresolved"
        return attach_nvd(
            CveHit(
                cve=cve_id,
                source="kubernetes",
                url=issue_url,
                module=module,
                affected=f"Kubernetes ({status})",
                description=row.blob.split(cve_id)[-1].strip()[:300] or None,
                release_notes_url=source.release_notes_url,
            )
        )
    return None
