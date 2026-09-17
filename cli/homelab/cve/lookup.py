from __future__ import annotations

from .models import CveHit, LibrarySource
from .parsers import search_cve_for_source
from .sources import CveConfig


def lookup_cve(
    cve_id: str,
    config: CveConfig,
    source: str | None = None,
) -> list[CveHit]:
    selected = source.lower() if source else None
    seen_providers: set[str] = set()
    results: list[CveHit] = []
    for library in config.libraries.values():
        if selected and selected not in {library.name, library.provider}:
            continue
        if library.provider in seen_providers and not selected:
            continue
        seen_providers.add(library.provider)
        found = search_cve_for_source(cve_id, library)
        if found:
            results.append(found)
    if selected and not results:
        dummy = LibrarySource(name=selected, provider=selected, cves_url="")
        found = search_cve_for_source(cve_id, dummy)
        if found:
            return [found]
    return results
