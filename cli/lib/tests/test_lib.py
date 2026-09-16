import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from homelab_cli.compose_hash import check_compose_file_changes
from homelab_cli.github_api import api_url, version_from_tag
from homelab_cli.markdown_commands import read_commands_from_md, should_execute_command


class GithubApiTests(unittest.TestCase):
    def test_public_github_api_host(self):
        url = api_url("https://github.com/org/repo.git", "ref/tags/v1.0.0")
        self.assertEqual(url, "https://api.github.com/repos/org/repo/git/ref/tags/v1.0.0")

    def test_ghes_api_v3_path(self):
        url = api_url("https://git.example.com/org/repo", "ref/tags/v1")
        self.assertEqual(url, "https://git.example.com/api/v3/repos/org/repo/git/ref/tags/v1")

    def test_version_from_tag(self):
        self.assertEqual(version_from_tag("v1.2.3_build"), "1.2.3")
        with self.assertRaises(ValueError):
            version_from_tag("nightly")


class MarkdownCommandTests(unittest.TestCase):
    def test_parses_user_container_bash(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cmds.md"
            path.write_text(
                "user root\ncontainer app\n```bash\necho hi\n```\n",
                encoding="utf-8",
            )
            blocks = read_commands_from_md(str(path))
            self.assertEqual(blocks[0]["User"], "root")
            self.assertEqual(blocks[0]["Container"], "app")
            self.assertIn("echo hi", blocks[0]["Bash"])

    def test_include_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "cfg.json"
            cfg.write_text(
                '{"include": ["db"], "sections": {"db": {"commands": ["psql"], "files": []}, "web": {"commands": ["curl"], "files": []}}}',
                encoding="utf-8",
            )
            self.assertTrue(should_execute_command("psql -l", str(cfg)))
            self.assertFalse(should_execute_command("curl localhost", str(cfg)))


class ComposeHashTests(unittest.TestCase):
    def test_first_run_not_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            yml = Path(tmp) / "compose.yml"
            yml.write_text("services: {}\n", encoding="utf-8")
            changed, digest = check_compose_file_changes(str(yml))
            self.assertFalse(changed)
            self.assertIsNotNone(digest)


if __name__ == "__main__":
    unittest.main()
