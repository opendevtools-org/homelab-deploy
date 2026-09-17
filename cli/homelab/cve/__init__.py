"""Inspect JAR versions and list fixed CVEs. Company data lives in JSON config."""

from .fixed import FixedCVE, LookupOnlyError, get_fixed_cves
from .ids import normalize_cve_ids
from .inventory import compare_cves_against_inventory, inventory_dependencies
from .jars import inspect_jar
from .lookup import lookup_cve
from .models import CveConfig, CveHit, JarMatch
from .scan import check_jar_version
from .sources import load_cve_config

__all__ = [
    "CveConfig",
    "CveHit",
    "FixedCVE",
    "JarMatch",
    "LookupOnlyError",
    "check_jar_version",
    "compare_cves_against_inventory",
    "get_fixed_cves",
    "inspect_jar",
    "inventory_dependencies",
    "load_cve_config",
    "lookup_cve",
    "normalize_cve_ids",
]
