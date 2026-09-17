"""Python / PSF / PyPA packages via NVD CPE."""

from __future__ import annotations

import re

from ..models import CveHit, LibrarySource
from ..nvd import attach_nvd, get_nvd_cve


def search_python_package(cve_id: str, source: LibrarySource) -> CveHit | None:
    cve_id = cve_id.upper()
    cve = get_nvd_cve(cve_id)
    if not cve:
        return None
    package = fixed_in = None
    for configuration in cve.get("configurations") or []:
        for node in configuration.get("nodes") or []:
            for match in node.get("cpeMatch") or []:
                cpe_match = re.match(r"cpe:2\.3:a:([^:]+):([^:]+):", match.get("criteria", ""))
                if cpe_match and cpe_match.group(1) in {"python", "psf", "pypa"}:
                    package, fixed_in = cpe_match.group(2), match.get("versionEndExcluding")
                    break
            if package:
                break
        if package:
            break
    if not package:
        return None
    return attach_nvd(
        CveHit(
            cve=cve_id,
            source="python",
            url=f"https://nvd.nist.gov/vuln/detail/{cve_id}",
            module=f"python:{package}",
            affected=f"< {fixed_in}" if fixed_in else None,
            fixed_in=fixed_in,
            release_notes_url=source.release_notes_url,
        )
    )
