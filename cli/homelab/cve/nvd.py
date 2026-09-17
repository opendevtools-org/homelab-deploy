from __future__ import annotations

import os
import time
from urllib.error import HTTPError

from net import fetch_json

from .models import CveHit

NVD_CVE_URL = "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId={}"
_CACHE: dict[str, dict | None] = {}
_LAST_REQUEST = 0.0


def _api_key() -> str | None:
    key = os.environ.get("NVD_API_KEY")
    if key:
        return key
    dotenv_path = os.environ.get("HOMELAB_CVE_DOTENV")
    if not dotenv_path:
        return None
    try:
        from env import dotenv_value
    except ImportError:
        return None
    return dotenv_value(dotenv_path, "NVD_API_KEY")


def _headers() -> dict[str, str]:
    headers: dict[str, str] = {}
    api_key = _api_key()
    if api_key:
        headers["apiKey"] = api_key
    return headers


def get_nvd_cve(cve_id: str) -> dict | None:
    global _LAST_REQUEST
    cve_id = cve_id.upper()
    if cve_id in _CACHE:
        return _CACHE[cve_id]
    interval = 0.6 if _api_key() else 6.0
    for attempt in range(3):
        wait = interval - (time.monotonic() - _LAST_REQUEST)
        if wait > 0:
            time.sleep(wait)
        try:
            data = fetch_json(NVD_CVE_URL.format(cve_id), headers=_headers())
            _LAST_REQUEST = time.monotonic()
            vulns = data.get("vulnerabilities") or []
            result = vulns[0]["cve"] if vulns else None
            _CACHE[cve_id] = result
            return result
        except HTTPError as error:
            _LAST_REQUEST = time.monotonic()
            if error.code == 429 and attempt < 2:
                time.sleep(interval)
                continue
            _CACHE[cve_id] = None
            return None
        except Exception:
            _CACHE[cve_id] = None
            return None
    _CACHE[cve_id] = None
    return None


def _english_description(cve: dict) -> str | None:
    for item in cve.get("descriptions") or []:
        if item.get("lang") == "en":
            return item.get("value")
    return None


def get_cve_details(cve_id: str) -> tuple[str | None, float | None, str | None]:
    cve = get_nvd_cve(cve_id)
    if not cve:
        return None, None, None
    description = _english_description(cve)
    metrics = cve.get("metrics", {})
    for key in ("cvssMetricV40", "cvssMetricV31", "cvssMetricV30"):
        if key in metrics:
            metric = metrics[key][0]
            return (
                metric["cvssData"].get("baseSeverity"),
                metric["cvssData"].get("baseScore"),
                description,
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
        return severity, score, description
    return None, None, description


def attach_nvd(hit: CveHit) -> CveHit:
    if not hit.cve.upper().startswith("CVE-"):
        return hit
    severity, score, description = get_cve_details(hit.cve)
    if hit.severity is None:
        hit.severity = severity
    if hit.cvss_score is None:
        hit.cvss_score = score
    if not hit.description:
        hit.description = description
    return hit
