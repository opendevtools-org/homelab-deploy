#!/usr/bin/env python3
"""Stdlib tests for Merge-SqliteGitConflict.py."""

from __future__ import annotations

import importlib.util
import sqlite3
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).with_name("Merge-SqliteGitConflict.py")


def load_helper():
    spec = importlib.util.spec_from_file_location("merge_sqlite_git_conflict", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


merge = load_helper()


def write_pkm_db(path: Path, pages: list[tuple[str, str, str]]) -> None:
    conn = sqlite3.connect(path)
    conn.execute(
        """
        CREATE TABLE pages (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.execute("CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL)")
    conn.execute("CREATE TABLE bookmarks (id TEXT PRIMARY KEY, updated_at TEXT)")
    conn.execute("CREATE TABLE hosted_files (id TEXT PRIMARY KEY)")
    conn.execute("CREATE TABLE pdf_documents (id TEXT PRIMARY KEY, indexed_at TEXT)")
    conn.execute("CREATE TABLE file_drive_links (id TEXT PRIMARY KEY, synced_at TEXT)")
    conn.executemany("INSERT INTO pages (id, title, updated_at) VALUES (?, ?, ?)", pages)
    conn.execute("INSERT INTO users (id, username) VALUES ('u1', 'admin')")
    conn.commit()
    conn.close()


class SqliteMergeTests(unittest.TestCase):
    def test_later_updated_at_wins_on_same_row(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            base = root / "base.db"
            local = root / "local.db"
            remote = root / "remote.db"
            out = root / "merged.db"
            write_pkm_db(base, [("p1", "Hello", "2026-01-01T00:00:00")])
            write_pkm_db(local, [("p1", "Local title", "2026-02-01T00:00:00")])
            write_pkm_db(remote, [("p1", "Remote title", "2026-01-15T00:00:00")])

            changes = merge.merge_databases(str(base), str(local), str(remote), str(out), "pkm")
            self.assertIn("pages", changes)

            conn = sqlite3.connect(out)
            title = conn.execute("SELECT title FROM pages WHERE id = 'p1'").fetchone()[0]
            conn.close()
            self.assertEqual(title, "Local title")

    def test_row_only_on_local_is_kept(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            base = root / "base.db"
            local = root / "local.db"
            remote = root / "remote.db"
            out = root / "merged.db"
            write_pkm_db(base, [("p1", "Hello", "2026-01-01T00:00:00")])
            write_pkm_db(
                local,
                [
                    ("p1", "Hello", "2026-01-01T00:00:00"),
                    ("p2", "Only local", "2026-03-01T00:00:00"),
                ],
            )
            write_pkm_db(remote, [("p1", "Hello", "2026-01-01T00:00:00")])

            merge.merge_databases(str(base), str(local), str(remote), str(out), "pkm")
            conn = sqlite3.connect(out)
            titles = {
                row[0]: row[1]
                for row in conn.execute("SELECT id, title FROM pages").fetchall()
            }
            conn.close()
            self.assertEqual(titles["p2"], "Only local")


if __name__ == "__main__":
    unittest.main()
