from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, TypeVar

CVE_RE = re.compile(r"CVE-\d{4}-\d+")


class LookupOnlyError(ValueError):
    """Provider has advisories for lookup-cve but not check-fixed-cve --version."""

T = TypeVar("T")


def unique_by(items: Iterable[T], key) -> list[T]:
    unique: dict[object, T] = {}
    for item in items:
        unique[key(item)] = item
    return list(unique.values())


def unique_by_cve(items: Iterable["CveHit"]) -> list["CveHit"]:
    return unique_by(items, lambda item: item.cve)


@dataclass
class CveHit:
    cve: str
    source: str = ""
    url: str = ""
    module: str | None = None
    affected: str | None = None
    fixed_in: str | None = None
    severity: str | None = None
    cvss_score: float | None = None
    description: str | None = None
    release_notes_url: str | None = None


FixedCVE = CveHit


@dataclass
class JarMatch:
    location: str
    containing_jar: str | None
    version: str | None
    version_source: str | None


@dataclass(frozen=True)
class LibrarySource:
    name: str
    provider: str
    cves_url: str
    release_notes_url: str | None = None

    @property
    def url(self) -> str:
        return self.cves_url


@dataclass(frozen=True)
class CveConfig:
    default_scan_root: str
    libraries: dict[str, LibrarySource]
