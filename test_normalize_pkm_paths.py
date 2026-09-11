#!/usr/bin/env python3
"""Stdlib tests for Normalize-PkmDuplicatePaths.py."""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).with_name("Normalize-PkmDuplicatePaths.py")


def load_helper():
    spec = importlib.util.spec_from_file_location("normalize_pkm_duplicate_paths", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


norm = load_helper()


class CanonicalTests(unittest.TestCase):
    def test_strips_duplicate_dash_one_only(self) -> None:
        self.assertEqual(norm.canonical_path("notes/install-1/page.md"), "notes/install/page.md")
        self.assertEqual(norm.canonical_path("notes/install-1.md"), "notes/install.md")
        self.assertEqual(norm.canonical_path("notes/ubuntu-22/page"), "notes/ubuntu-22/page")
        self.assertEqual(norm.canonical_path("notes/item-11"), "notes/item-11")


class FsAndPositionTests(unittest.TestCase):
    def test_renames_orphan_dash_one_dir(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            docs = root / "data" / "pkm" / "docs"
            dup = docs / "guide-1"
            dup.mkdir(parents=True)
            (dup / "guide-1.md").write_text("body", encoding="utf-8")
            msgs = norm.apply_fs(docs, root, "host", "20260101-000000")
            self.assertTrue((docs / "guide").is_dir())
            self.assertTrue((docs / "guide" / "guide.md").is_file())
            self.assertFalse((docs / "guide-1").exists())
            self.assertTrue(any("guide-1" in m for m in msgs))

    def test_merges_into_existing_canonical_dir(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            docs = root / "data" / "pkm" / "docs"
            canon = docs / "guide"
            dup = docs / "guide-1"
            canon.mkdir(parents=True)
            dup.mkdir(parents=True)
            (canon / "keep.md").write_text("a", encoding="utf-8")
            (dup / "extra.md").write_text("b", encoding="utf-8")
            (dup / "keep.md").write_text("a", encoding="utf-8")
            norm.apply_fs(docs, root, "host", "20260101-000000")
            self.assertTrue((canon / "extra.md").is_file())
            self.assertFalse(dup.exists())

    def test_position_snapshot_uses_canonical_keys(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            db = root / "pkm.db"
            snap = root / "pos.json"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE pages (path TEXT, position INTEGER)")
            conn.execute("INSERT INTO pages VALUES ('guide-1/intro', 3)")
            conn.commit()
            conn.close()
            norm.snapshot_positions(db, snap)
            data = json.loads(snap.read_text(encoding="utf-8"))
            self.assertEqual(data["guide/intro"], 3)

            conn = sqlite3.connect(db)
            conn.execute("DELETE FROM pages")
            conn.execute("INSERT INTO pages VALUES ('guide/intro', 9)")
            conn.commit()
            conn.close()
            n = norm.restore_positions(db, snap)
            self.assertEqual(n, 1)
            conn = sqlite3.connect(db)
            pos = conn.execute("SELECT position FROM pages WHERE path='guide/intro'").fetchone()[0]
            conn.close()
            self.assertEqual(pos, 3)

    def test_restore_positions_breaks_sibling_ties(self) -> None:
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            root = Path(tmp)
            db = root / "pkm.db"
            snap = root / "pos.json"
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE pages (path TEXT, parent_id TEXT, position REAL)")
            conn.executemany(
                "INSERT INTO pages VALUES (?, ?, ?)",
                [("z.md", "root", 29), ("a.md", "root", 29)],
            )
            conn.commit()
            conn.close()
            snap.write_text(json.dumps({"z.md": 4, "a.md": 4}), encoding="utf-8")

            self.assertEqual(norm.restore_positions(db, snap), 2)
            conn = sqlite3.connect(db)
            rows = conn.execute("SELECT path, position FROM pages ORDER BY position").fetchall()
            conn.close()
            self.assertEqual(rows, [("a.md", 4), ("z.md", 5)])


if __name__ == "__main__":
    unittest.main()
