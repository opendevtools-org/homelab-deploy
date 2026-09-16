from __future__ import annotations

import json
from urllib.request import urlopen


def get_cve_details(cve_id: str) -> tuple[str | None, float | None]:
    url = f"https://services.nvd.nist.gov/rest/json/cves/2.0?cveId={cve_id}"
    try:
        with urlopen(url, timeout=30) as response:
            data = json.loads(response.read().decode())
        if not data.get("vulnerabilities"):
            return None, None
        cve = data["vulnerabilities"][0]["cve"]
        metrics = cve.get("metrics", {})
        for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30"):
            if key in metrics:
                metric = metrics[key][0]
                return (
                    metric["cvssData"].get("baseSeverity"),
                    metric["cvssData"].get("baseScore"),
                )
        if "cvssMetricV2" in metrics:
            metric = metrics["cvssMetricV2"][0]
            severity = metric.get("baseSeverity")
            score = metric["cvssData"].get("baseScore")
            if severity is None and score is not None:
                if score >= 7:
                    severity = "HIGH"
                elif score >= 4:
                    severity = "MEDIUM"
                else:
                    severity = "LOW"
            return severity, score
    except Exception:
        return None, None
    return None, None
