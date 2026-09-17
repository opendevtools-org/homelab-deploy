from __future__ import annotations

import json
from urllib.request import Request, urlopen

USER_AGENT = "homelab-lib/1.0"


def fetch_text(url: str, timeout: int = 30, headers: dict[str, str] | None = None) -> str:
    merged = {"User-Agent": USER_AGENT}
    if headers:
        merged.update(headers)
    request = Request(url, headers=merged)
    with urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def fetch_json(url: str, timeout: int = 30, headers: dict[str, str] | None = None):
    return json.loads(fetch_text(url, timeout=timeout, headers=headers))
