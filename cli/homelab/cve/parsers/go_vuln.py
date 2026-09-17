"""Go vulnerability database (https://vuln.go.dev)."""

from __future__ import annotations

from net import fetch_json
from ..models import CveHit, LibrarySource
from ..nvd import attach_nvd

GO_RECORD_URL = "https://vuln.go.dev/ID/{go_id}.json"


def _alias_index(index_url: str) -> dict[str, str]:
    data = fetch_json(index_url)
    mapping: dict[str, str] = {}
    for item in data:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        for alias in item.get("aliases") or []:
            if isinstance(alias, str):
                mapping[alias.upper()] = item["id"]
    return mapping


def _result_from_record(record: dict, cve_id: str, url: str, source: LibrarySource) -> CveHit | None:
    packages = [item.get("package", {}).get("name") for item in record.get("affected") or []]
    module = next((item for item in packages if item), None)
    if not module:
        return None
    fixed = [
        event["fixed"]
        for item in record.get("affected") or []
        if item.get("package", {}).get("name") == module
        for range_item in item.get("ranges") or []
        for event in range_item.get("events") or []
        if event.get("fixed")
    ]
    hit = CveHit(
        cve=cve_id,
        source="go",
        url=url,
        module=module,
        affected="Go vulnerability database record",
        fixed_in=", ".join(dict.fromkeys(fixed)) or None,
        description=record.get("summary"),
        release_notes_url=source.release_notes_url,
    )
    return attach_nvd(hit) if cve_id.startswith("CVE-") else hit


def search_go(cve_id: str, source: LibrarySource) -> CveHit | None:
    cve_id = cve_id.upper()
    go_id = cve_id if cve_id.startswith("GO-") else _alias_index(source.cves_url).get(cve_id)
    if not go_id:
        return None
    record_url = GO_RECORD_URL.format(go_id=go_id)
    try:
        record = fetch_json(record_url)
    except Exception:
        return None
    aliases = {alias.upper() for alias in record.get("aliases") or []}
    if go_id != cve_id and cve_id not in aliases:
        return None
    return _result_from_record(record, cve_id, record_url, source)
