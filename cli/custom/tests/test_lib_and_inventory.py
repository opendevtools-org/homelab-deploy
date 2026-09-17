import tempfile
import unittest
from pathlib import Path

import paths  # noqa: F401
from env import dotenv_value
from github import api_url
from homelab.cve.ids import normalize_cve_ids
from homelab.cve.inventory import compare_cves_against_inventory, inventory_dependencies
from homelab.cve.models import CveHit


class IdTests(unittest.TestCase):
    def test_splits_commas_and_spaces(self):
        self.assertEqual(
            normalize_cve_ids(["CVE-2024-1", "cve-2024-2,GO-2024-1"]),
            ["CVE-2024-1", "CVE-2024-2", "GO-2024-1"],
        )


class InventoryTests(unittest.TestCase):
    def test_compares_fixed_in(self):
        inventory = inventory_dependencies(
            {"dependencies": [{"group": "org.example", "artifact": "lib", "version": "1.0.0"}]}
        )
        hits = [CveHit(cve="CVE-1", module="org.example:lib", fixed_in="1.2.0")]
        rows = compare_cves_against_inventory(inventory, hits)
        self.assertEqual(rows[0]["status"], "affected")


class DotenvTests(unittest.TestCase):
    def test_reads_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".env"
            path.write_text("NVD_API_KEY=abc\n", encoding="utf-8")
            self.assertEqual(dotenv_value(path, "NVD_API_KEY"), "abc")


class GithubUrlTests(unittest.TestCase):
    def test_public_github(self):
        url = api_url("https://github.com/org/repo.git", "ref/tags/v1.0.0")
        self.assertEqual(url, "https://api.github.com/repos/org/repo/git/ref/tags/v1.0.0")


class PkmFormTests(unittest.TestCase):
    def test_lookup_argv(self):
        from homelab.cve.pkm_form import argv_from_form

        argv = argv_from_form(
            {"command": "lookup-cve", "cve": "CVE-2024-1, GO-2024-2", "json_output": True}
        )
        self.assertEqual(
            argv,
            ["lookup-cve", "--cve", "CVE-2024-1", "GO-2024-2", "--json"],
        )

    def test_fixed_requires_library(self):
        from homelab.cve.pkm_form import argv_from_form

        with self.assertRaises(ValueError):
            argv_from_form({"command": "check-fixed-cve", "library": "openssl"})


if __name__ == "__main__":
    unittest.main()
