from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from ..models import CveHit, LibrarySource, LookupOnlyError
from .curl import get_curl_fixed_cves, search_curl
from .cxf import get_cxf_fixed_cves, search_cxf
from .go_vuln import search_go
from .kubernetes import search_kubernetes
from .openssl import get_openssl_fixed_cves, search_openssl
from .python_packages import search_python_package
from .semeru import get_semeru_fixed_cves, search_semeru


@dataclass(frozen=True)
class Provider:
    name: str
    search: Callable[[str, LibrarySource], CveHit | None]
    fixed: Callable[[str, LibrarySource], list[CveHit]] | None = None
    aliases: tuple[str, ...] = ()

    @property
    def supports_fixed(self) -> bool:
        return self.fixed is not None


PROVIDERS: tuple[Provider, ...] = (
    Provider("openssl", search_openssl, get_openssl_fixed_cves),
    Provider("curl", search_curl, get_curl_fixed_cves),
    Provider("cxf", search_cxf, get_cxf_fixed_cves, aliases=("apache",)),
    Provider("go", search_go),
    Provider("kubernetes", search_kubernetes),
    Provider("python", search_python_package),
    Provider("semeru", search_semeru, get_semeru_fixed_cves),
)


def _by_name() -> dict[str, Provider]:
    mapping: dict[str, Provider] = {}
    for provider in PROVIDERS:
        mapping[provider.name] = provider
        for alias in provider.aliases:
            mapping[alias] = provider
    return mapping


PROVIDERS_BY_NAME = _by_name()
SEARCH = {name: provider.search for name, provider in PROVIDERS_BY_NAME.items()}
FIXED = {name: provider.fixed for name, provider in PROVIDERS_BY_NAME.items() if provider.fixed}


def provider_for(name: str) -> Provider | None:
    return PROVIDERS_BY_NAME.get(name)


def get_fixed_cves_for_source(version: str, source: LibrarySource) -> list[CveHit]:
    provider = provider_for(source.provider)
    if provider is None:
        known = ", ".join(sorted({item.name for item in PROVIDERS}))
        raise ValueError(
            f"Unsupported provider '{source.provider}' for library {source.name}. "
            f"Known parsers: {known}"
        )
    if provider.fixed is None:
        raise LookupOnlyError(
            f"{provider.name} supports lookup-cve only, not check-fixed-cve --version"
        )
    return provider.fixed(version, source)


def search_cve_for_source(cve_id: str, source: LibrarySource) -> CveHit | None:
    provider = provider_for(source.provider)
    if provider is None:
        return None
    hit = provider.search(cve_id, source)
    if hit and source.release_notes_url and not hit.release_notes_url:
        hit.release_notes_url = source.release_notes_url
    return hit
