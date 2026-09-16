from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class LibrarySource:
    name: str
    url: str
    provider: str


@dataclass(frozen=True)
class CveConfig:
    default_scan_root: str
    libraries: dict[str, LibrarySource]


def default_config() -> CveConfig:
    example = Path(__file__).resolve().parents[1] / "config" / "sources.example.json"
    return load_cve_config(example)


def load_cve_config(path: str | Path | None) -> CveConfig:
    if path is None:
        return default_config()
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    libraries = {}
    for name, spec in (data.get("libraries") or {}).items():
        libraries[name.lower()] = LibrarySource(
            name=name.lower(),
            url=spec["url"],
            provider=spec.get("provider", name.lower()),
        )
    return CveConfig(
        default_scan_root=data.get("default_scan_root") or "/",
        libraries=libraries,
    )
