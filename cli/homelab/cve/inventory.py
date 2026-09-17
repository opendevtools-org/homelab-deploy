"""Dependency inventory loading and CVE classification."""

from __future__ import annotations

import re


def dependency_module(dependency: dict) -> str:
    group = str(dependency.get("group", ""))
    artifact = str(dependency.get("artifact", ""))
    if group == "golang.org":
        return f"{group}/{artifact}".strip("/")
    return f"{group}:{artifact}".strip(":")


def inventory_dependencies(inventory_data: object) -> list[dict] | None:
    if isinstance(inventory_data, list):
        return inventory_data
    if not isinstance(inventory_data, dict):
        return None

    dependencies = list(inventory_data.get("dependencies") or [])
    for executable in (inventory_data.get("executables") or {}).values():
        if not isinstance(executable, dict):
            continue
        runtime = executable.get("runtime")
        if isinstance(runtime, dict):
            dependencies.append(runtime)
        dependencies.extend(item for item in executable.get("dependencies") or [] if isinstance(item, dict))

    unique: dict[tuple[str, str], dict] = {}
    for dependency in dependencies:
        if not isinstance(dependency, dict):
            continue
        key = (dependency_module(dependency), str(dependency.get("version") or ""))
        unique[key] = dependency
    return list(unique.values())


def version_is_affected(version: str | None, fixed_versions: str | list[str] | None) -> bool:
    if not version or fixed_versions is None:
        return False
    if isinstance(fixed_versions, str):
        if "no upstream fix" in fixed_versions.lower():
            return True
        fixed_versions = re.split(r"[\s,]+", fixed_versions)
    version_match = re.match(r"^v?(\d+(?:\.\d+)+)", version.strip())
    if not version_match:
        return False
    current = [int(part) for part in version_match.group(1).split(".")]
    for fixed_version in fixed_versions:
        if not fixed_version:
            continue
        fixed_match = re.match(r"^v?(\d+(?:\.\d+)+)", str(fixed_version).strip())
        if fixed_match and current < [int(part) for part in fixed_match.group(1).split(".")]:
            return True
    return False


def compare_inventory_against_cves(inventory: list[dict], cve_results: list[object]) -> list[dict]:
    cve_by_module: dict[str, list[object]] = {}
    for result in cve_results:
        cve_by_module.setdefault(getattr(result, "module", None) or "unknown", []).append(result)

    findings = []
    for dependency in inventory:
        module = dependency_module(dependency)
        version = str(dependency.get("version") or "")
        matched = cve_by_module.get(module, [])
        affected = [
            result.cve
            for result in matched
            if version_is_affected(version, getattr(result, "fixed_in", None))
        ]
        findings.append(
            {
                "group": dependency.get("group"),
                "artifact": dependency.get("artifact"),
                "version": version,
                "file": dependency.get("file"),
                "module": module,
                "status": "affected" if affected else "not_affected" if matched else "false_positive",
                "matched_cves": affected,
                "matched_cve_count": len(affected),
                "possible_matches": [getattr(item, "cve", None) for item in matched],
            }
        )
    return findings


def compare_cves_against_inventory(inventory: list[dict], cve_results: list[object]) -> list[dict]:
    dependencies = {item.get("module") or dependency_module(item): item for item in inventory}
    findings = []
    for result in cve_results:
        module = getattr(result, "module", None) or "unknown"
        dependency = dependencies.get(module) or (dependencies.get("go") if module == "stdlib" else None)
        version = str(dependency.get("version") or "") if dependency else None
        fixed_in = getattr(result, "fixed_in", None)
        if dependency is None:
            status = "not_present"
        elif not fixed_in:
            status = "unknown"
        elif version_is_affected(version, fixed_in):
            status = "affected"
        else:
            status = "not_affected"
        findings.append(
            {
                "cve": result.cve,
                "module": module,
                "artifact_version": version,
                "component": dependency.get("component") if dependency else None,
                "file": dependency.get("file") if dependency else None,
                "status": status,
                "severity": getattr(result, "severity", None),
                "cvss_score": getattr(result, "cvss_score", None),
                "fixed_in": fixed_in,
            }
        )
    return findings
