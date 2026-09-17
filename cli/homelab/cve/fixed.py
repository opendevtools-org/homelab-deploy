from __future__ import annotations

from .models import CVE_RE, CveHit, FixedCVE, LibrarySource, LookupOnlyError
from .sources import CveConfig

__all__ = ["CVE_RE", "CveHit", "FixedCVE", "LookupOnlyError", "get_fixed_cves"]


def get_fixed_cves(library: str, version: str, config: CveConfig) -> list[CveHit]:
    key = library.lower()
    source: LibrarySource | None = config.libraries.get(key)
    if source is None:
        raise ValueError(
            f"Library not in config: {library}. Known: {', '.join(sorted(config.libraries)) or '(none)'}"
        )
    from .parsers import get_fixed_cves_for_source

    hits = get_fixed_cves_for_source(version, source)
    notes = source.release_notes_url
    if notes:
        for hit in hits:
            if not hit.release_notes_url:
                hit.release_notes_url = notes
    return hits
