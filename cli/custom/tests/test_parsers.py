import json
import tempfile
import unittest

import paths  # noqa: F401
from paths import CVE_ROOT, FIXTURES
from homelab.cve.fixed import LookupOnlyError
from homelab.cve.models import CveHit, LibrarySource, unique_by_cve
from homelab.cve.parsers import FIXED, SEARCH, get_fixed_cves_for_source
from homelab.cve.parsers.curl import parse_curl_advisories
from homelab.cve.parsers.cxf import RANGE_RE
from homelab.cve.parsers.openssl import parse_openssl_advisories
from homelab.cve.sources import load_cve_config
from markup import parse_tables
from versions import in_closed, in_half_open


class CurlParserTests(unittest.TestCase):
    def test_parses_security_table(self):
        html = (FIXTURES / "curl-security.html").read_text(encoding="utf-8")
        rows = parse_curl_advisories(html, "https://curl.se/docs/security.html")
        by_id = {row.cve: row for row in rows}
        self.assertIn("CVE-2026-82209", by_id)
        row = by_id["CVE-2026-82209"]
        self.assertEqual(row.first_affected, "7.46.0")
        self.assertEqual(row.last_affected, "8.21.0")
        self.assertEqual(row.published, "2026-09-02")
        self.assertEqual(row.advisory_url, "https://curl.se/docs/CVE-2026-82209.html")
        self.assertIn("PSL", row.title or "")
        self.assertEqual(by_id["CVE-2025-5025"].last_affected, "8.13.0")


class OpenSSLParserTests(unittest.TestCase):
    def test_parses_from_before_ranges(self):
        html = """
        <h3>CVE-2024-0001</h3>
        <div>from 3.0.0 before 3.0.16</div>
        <h3>CVE-2024-0002</h3>
        <div>from 3.1.0 before 3.1.8</div>
        """
        rows = parse_openssl_advisories(html, "https://example.com/openssl")
        by_id = {row.cve: row for row in rows}
        self.assertEqual(by_id["CVE-2024-0001"].ranges, [("3.0.0", "3.0.16")])
        self.assertEqual(by_id["CVE-2024-0002"].ranges[0][1], "3.1.8")


class CxfParserTests(unittest.TestCase):
    def test_parses_before_ranges(self):
        text = "- Apache CXF (core) 3.5.0 before 3.5.10"
        match = RANGE_RE.findall(text)
        self.assertEqual(match[0][0], "core")
        self.assertEqual(match[0][2], "3.5.10")


class VersionRangeTests(unittest.TestCase):
    def test_half_open_and_closed(self):
        self.assertTrue(in_half_open("3.0.15", "3.0.0", "3.0.16"))
        self.assertFalse(in_half_open("3.0.16", "3.0.0", "3.0.16"))
        self.assertTrue(in_closed("8.21.0", "7.46.0", "8.21.0"))


class RegistryTests(unittest.TestCase):
    def test_imported_providers(self):
        for name in ("openssl", "curl", "cxf", "go", "kubernetes", "python", "semeru"):
            self.assertIn(name, SEARCH)
        for name in ("openssl", "curl", "cxf", "semeru"):
            self.assertIn(name, FIXED)
        for name in ("go", "kubernetes", "python"):
            self.assertNotIn(name, FIXED)

    def test_lookup_only_raises(self):
        source = LibrarySource(name="go", provider="go", cves_url="https://example.com")
        with self.assertRaises(LookupOnlyError):
            get_fixed_cves_for_source("1.22.0", source)


class UniqueAndHtmlTests(unittest.TestCase):
    def test_unique_by_cve(self):
        hits = [
            CveHit(cve="CVE-1", source="a"),
            CveHit(cve="CVE-1", source="b"),
            CveHit(cve="CVE-2", source="a"),
        ]
        unique = unique_by_cve(hits)
        self.assertEqual([item.cve for item in unique], ["CVE-1", "CVE-2"])
        self.assertEqual(unique[0].source, "b")

    def test_parse_tables_cells_and_hrefs(self):
        html = """
        <table>
          <tr class="cve-status-fixed"><td><a href="CVE-2024-1.html">CVE-2024-1</a></td><td><a href="vuln-8.1.0.html">8.1</a></td></tr>
        </table>
        """
        tables = parse_tables(html)
        row = tables[0][0]
        self.assertEqual(row.cells[0], "CVE-2024-1")
        self.assertIn("CVE-2024-1.html", row.hrefs[0])
        self.assertIn("cve-status-fixed", row.classes)


class SourcesJsonTests(unittest.TestCase):
    def test_example_has_cves_and_release_notes_urls(self):
        path = CVE_ROOT / "config" / "sources.example.json"
        config = load_cve_config(path)
        curl = config.libraries["curl"]
        self.assertEqual(curl.provider, "curl")
        self.assertEqual(curl.cves_url, "https://curl.se/docs/security.html")
        self.assertEqual(curl.release_notes_url, "https://curl.se/docs/releases.html")

    def test_legacy_url_key_still_loads(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as handle:
            json.dump(
                {"libraries": {"openssl": {"provider": "openssl", "url": "https://example.com/cves"}}},
                handle,
            )
            path = handle.name
        config = load_cve_config(path)
        self.assertEqual(config.libraries["openssl"].cves_url, "https://example.com/cves")


if __name__ == "__main__":
    unittest.main()
