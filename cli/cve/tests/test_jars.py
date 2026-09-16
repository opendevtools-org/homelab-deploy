import io
import sys
import unittest
import zipfile
from pathlib import Path

CVE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CVE_ROOT))

from homelab_cve.jars import inspect_jar
from homelab_cve.sources import load_cve_config


def make_jar(*entries: tuple[str, bytes]) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, data in entries:
            archive.writestr(name, data)
    return output.getvalue()


class JarInspectionTests(unittest.TestCase):
    def test_finds_version_in_nested_jar(self):
        target = make_jar(
            ("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\nImplementation-Version: 2.4.7\n")
        )
        outer = make_jar(("lib/target.jar", target))
        matches = inspect_jar(outer, "target.jar", "/app/outer.jar")
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0].location, "lib/target.jar")
        self.assertEqual(matches[0].containing_jar, "/app/outer.jar")
        self.assertEqual(matches[0].version, "2.4.7")
        self.assertEqual(matches[0].version_source, "manifest:Implementation-Version")

    def test_finds_version_in_nested_maven_properties(self):
        target = make_jar(("META-INF/maven/example/library/pom.properties", b"version=1.8.0\n"))
        outer = make_jar(("BOOT-INF/lib/library.jar", target))
        matches = inspect_jar(outer, "library.jar", "/app/application.jar")
        self.assertEqual(matches[0].version, "1.8.0")
        self.assertTrue(matches[0].version_source.endswith("pom.properties:version"))


class SourcesTests(unittest.TestCase):
    def test_example_config_loads_openssl(self):
        path = CVE_ROOT / "config" / "sources.example.json"
        config = load_cve_config(path)
        self.assertEqual(config.default_scan_root, "/")
        self.assertEqual(config.libraries["openssl"].provider, "openssl")


if __name__ == "__main__":
    unittest.main()
