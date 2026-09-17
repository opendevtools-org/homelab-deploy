"""Map a PKM form JSON object to ``homelab.cve`` argv (no ``python -m``)."""

from __future__ import annotations

from typing import Any


COMMANDS = (
    "lookup-cve",
    "check-fixed-cve",
    "check-jar-version",
    "compare-inventory",
)


def _text(params: dict[str, Any], key: str) -> str:
    value = params.get(key)
    if value is None:
        return ""
    return str(value).strip()


def _flag(params: dict[str, Any], key: str) -> bool:
    value = params.get(key)
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def _cve_ids(params: dict[str, Any], *keys: str) -> list[str]:
    raw = ""
    for key in keys or ("cve",):
        raw = _text(params, key)
        if raw:
            break
    raw = raw.replace(",", " ")
    return [part for part in raw.split() if part]


def argv_from_form(params: dict[str, Any]) -> list[str]:
    """Return argv after the module name, e.g. ``['lookup-cve', '--cve', 'CVE-2024-1']``."""
    command = _text(params, "command") or "lookup-cve"
    if command not in COMMANDS:
        raise ValueError(f"Unknown command: {command}. Known: {', '.join(COMMANDS)}")

    argv: list[str] = []
    config = _text(params, "config")
    if config:
        argv.extend(["--config", config])
    argv.append(command)

    if command == "lookup-cve":
        ids = _cve_ids(params, "cve")
        if not ids:
            raise ValueError("lookup-cve needs at least one id in the CVE field")
        argv.extend(["--cve", *ids])
        source = _text(params, "source")
        if source:
            argv.extend(["--source", source])
        inventory = _text(params, "inventory")
        if inventory:
            argv.extend(["--inventory", inventory])
    elif command == "check-fixed-cve":
        library = _text(params, "library")
        version = _text(params, "version")
        if not library or not version:
            raise ValueError("check-fixed-cve needs library and version")
        argv.extend(["--library", library, "--version", version])
    elif command == "check-jar-version":
        jar = _text(params, "jar")
        container = _text(params, "container")
        if not jar or not container:
            raise ValueError("check-jar-version needs jar and container")
        argv.extend(["--jar", jar, "--container", container])
        root = _text(params, "root")
        if root:
            argv.extend(["--root", root])
        if _flag(params, "no_color"):
            argv.append("--no-color")
    else:
        inventory = _text(params, "compare_inventory") or _text(params, "inventory")
        ids = _cve_ids(params, "compare_cve", "cve")
        if not inventory or not ids:
            raise ValueError("compare-inventory needs inventory path and CVE ids")
        argv.extend(["--inventory", inventory, "--cve", *ids])
        source = _text(params, "compare_source") or _text(params, "source")
        if source:
            argv.extend(["--source", source])

    if _flag(params, "json_output"):
        argv.append("--json")
    return argv
