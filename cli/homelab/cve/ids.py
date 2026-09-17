from __future__ import annotations

import re

CVE_OR_GO = re.compile(r"(?:CVE|GO)-\d{4}-\d+", re.IGNORECASE)


def normalize_cve_ids(values: str | list[str] | tuple[str, ...]) -> list[str]:
    raw_values = [values] if isinstance(values, str) else list(values)
    normalized: list[str] = []
    seen: set[str] = set()
    for raw_value in raw_values:
        if raw_value is None:
            continue
        for item in re.split(r"[\s,]+", str(raw_value).strip()):
            item = item.strip(" ,;\t\r\n")
            if not item or not CVE_OR_GO.fullmatch(item):
                continue
            cve_id = item.upper()
            if cve_id not in seen:
                seen.add(cve_id)
                normalized.append(cve_id)
    return normalized
