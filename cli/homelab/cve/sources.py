from __future__ import annotations

import json
from pathlib import Path

from .models import CveConfig, LibrarySource


def default_config() -> CveConfig:
    example = Path(__file__).resolve().parent / "config" / "sources.example.json"
    return load_cve_config(example)


def load_cve_config(path: str | Path | None) -> CveConfig:
    if path is None:
        return default_config()
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    libraries = {}
    for name, spec in (data.get("libraries") or {}).items():
        cves_url = spec.get("cves_url") or spec.get("url")
        if not cves_url:
            raise ValueError(f"Library {name} needs cves_url (advisory list page)")
        libraries[name.lower()] = LibrarySource(
            name=name.lower(),
            provider=spec.get("provider", name.lower()),
            cves_url=cves_url,
            release_notes_url=spec.get("release_notes_url"),
        )
    return CveConfig(
        default_scan_root=data.get("default_scan_root") or "/",
        libraries=libraries,
    )
