#!/usr/bin/env python3
"""Collapse PKM Git/OS duplicate names (folder or page.md ending in -1).

When two site instances sync the same wiki tree, a second copy often lands as
``name-1`` next to ``name``. That is a generic collision, not a site-specific
slug. This helper:

* maps those paths to the canonical name (strip a final ``-1`` segment)
* snapshots / restores ``pages.position`` using canonical keys
* merges ``*-1`` directories and ``*-1.md`` files into the canonical sibling
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sqlite3
import sys
from pathlib import Path

DUP_SEGMENT = re.compile(r"^(.+)-1$")


def canonical_segment(part: str) -> str:
    match = DUP_SEGMENT.match(part)
    return match.group(1) if match else part


def canonical_path(path: str) -> str:
    parts = [p for p in path.replace("\\", "/").split("/") if p]
    normalized = []
    for index, part in enumerate(parts):
        if index == len(parts) - 1 and "." in part and not part.startswith("."):
            stem, suffix = part.rsplit(".", 1)
            normalized.append(f"{canonical_segment(stem)}.{suffix}")
        else:
            normalized.append(canonical_segment(part))
    return "/".join(normalized)


def snapshot_positions(db_path: Path, output_path: Path) -> int:
    if not db_path.is_file():
        output_path.write_text("{}", encoding="utf-8")
        return 0
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute("SELECT path, position FROM pages").fetchall()
    finally:
        conn.close()
    data = {canonical_path(path): position for path, position in rows}
    output_path.write_text(json.dumps(data), encoding="utf-8")
    return len(data)


def restore_positions(db_path: Path, snapshot_path: Path) -> int:
    if not db_path.is_file() or not snapshot_path.is_file():
        return 0
    positions = json.loads(snapshot_path.read_text(encoding="utf-8"))
    if not isinstance(positions, dict) or not positions:
        return 0
    conn = sqlite3.connect(db_path)
    updated = 0
    try:
        with conn:
            columns = {row[1] for row in conn.execute("PRAGMA table_info(pages)")}
            if "parent_id" in columns:
                rows = conn.execute("SELECT path, parent_id FROM pages").fetchall()
            else:
                rows = [(path, None) for (path,) in conn.execute("SELECT path FROM pages").fetchall()]
            matched = []
            for path, parent_id in rows:
                position = positions.get(canonical_path(path))
                if position is not None:
                    matched.append((parent_id, path, position))

            by_parent = {}
            for parent_id, path, position in matched:
                by_parent.setdefault(parent_id, []).append((path, position))
            for siblings in by_parent.values():
                siblings.sort(key=lambda item: (item[1], item[0]))
                previous_position = None
                for _index, (path, position) in enumerate(siblings):
                    if previous_position is not None and position <= previous_position:
                        position = previous_position + 1
                    conn.execute(
                        "UPDATE pages SET position=? WHERE path=?",
                        (position, path),
                    )
                    previous_position = position
                    updated += 1
    finally:
        conn.close()
    return updated


def _archive_path(repo_root: Path, relative: Path, host: str, stamp: str) -> Path:
    stem = relative.name
    ext = ""
    if "." in stem and not stem.startswith("."):
        ext = stem[stem.rfind(".") :]
        stem = stem[: -len(ext)]
    parent = relative.parent
    n = 0
    while True:
        extra = "" if n == 0 else f".{n}"
        name = f"{stem}.local-conflict.{host}.{stamp}{extra}{ext}"
        candidate = (repo_root / parent / name) if str(parent) != "." else repo_root / name
        if not candidate.exists():
            return candidate
        n += 1


def _merge_file(source: Path, target: Path, repo_root: Path, host: str, stamp: str) -> str | None:
    rel_source = source.relative_to(repo_root).as_posix()
    rel_target = target.relative_to(repo_root).as_posix()
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        source.rename(target)
        return f"Restored PKM file {rel_source} as {rel_target}."
    if source.read_bytes() == target.read_bytes():
        source.unlink()
        return None
    archive = _archive_path(repo_root, target.relative_to(repo_root), host, stamp)
    archive.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, archive)
    source.unlink()
    return (
        f"Duplicate PKM file preserved as {archive.relative_to(repo_root).as_posix()}; "
        "review before deleting it."
    )


def apply_fs(docs_root: Path, repo_root: Path, host: str, stamp: str) -> list[str]:
    messages: list[str] = []
    if not docs_root.is_dir():
        return messages

    dirs = sorted(
        (p for p in docs_root.rglob("*") if p.is_dir() and DUP_SEGMENT.match(p.name)),
        key=lambda p: len(p.parts),
        reverse=True,
    )
    for source in dirs:
        target = source.with_name(canonical_segment(source.name))
        rel_source = source.relative_to(docs_root).as_posix()
        rel_target = target.relative_to(docs_root).as_posix()
        if not target.exists():
            source.rename(target)
            messages.append(f"Restored PKM directory {rel_source} as {rel_target}.")
            continue
        for source_file in sorted(p for p in source.rglob("*") if p.is_file()):
            relative = source_file.relative_to(source)
            target_file = target / relative
            msg = _merge_file(source_file, target_file, repo_root, host, stamp)
            if msg:
                messages.append(msg)
        for leftover in sorted(source.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if leftover.is_dir():
                try:
                    leftover.rmdir()
                except OSError:
                    pass
        if not source.exists():
            messages.append(f"Merged duplicate PKM directory {rel_source} into {rel_target}.")
        elif not any(source.iterdir()):
            source.rmdir()
            messages.append(f"Merged duplicate PKM directory {rel_source} into {rel_target}.")

    md_files = sorted(
        p
        for p in docs_root.rglob("*.md")
        if p.is_file() and DUP_SEGMENT.match(p.stem)
    )
    for source in md_files:
        target = source.with_name(f"{canonical_segment(source.stem)}.md")
        msg = _merge_file(source, target, repo_root, host, stamp)
        if msg:
            messages.append(msg)
    return messages


def _pick_python_stamp(args: argparse.Namespace) -> tuple[str, str]:
    return args.host or "unknown-host", args.stamp or "conflict"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    snap = sub.add_parser("snapshot", help="Write canonical page positions JSON")
    snap.add_argument("--db", required=True, type=Path)
    snap.add_argument("--out", required=True, type=Path)

    rest = sub.add_parser("restore", help="Apply snapshot positions onto pages.path")
    rest.add_argument("--db", required=True, type=Path)
    rest.add_argument("--from-json", required=True, type=Path, dest="from_json")

    fs = sub.add_parser("apply-fs", help="Merge *-1 dirs and *-1.md into canonical names")
    fs.add_argument("--docs", required=True, type=Path)
    fs.add_argument("--repo", required=True, type=Path)
    fs.add_argument("--host", default="unknown-host")
    fs.add_argument("--stamp", default="conflict")

    args = parser.parse_args(argv)
    if args.cmd == "snapshot":
        n = snapshot_positions(args.db, args.out)
        print(f"snapshotted {n} PKM page positions")
        return 0
    if args.cmd == "restore":
        n = restore_positions(args.db, args.from_json)
        print(f"restored {n} PKM page positions")
        return 0
    host, stamp = _pick_python_stamp(args)
    for line in apply_fs(args.docs, args.repo, host, stamp):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
