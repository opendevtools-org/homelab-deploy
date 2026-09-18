#!/usr/bin/env python3
"""Print PKM sidebar folder order from pkm.db (no page bodies)."""
from __future__ import annotations

import os
import sqlite3
import sys


def _roots(db_path: str) -> list[tuple[str, str, str]]:
    uri = f"file:{os.path.abspath(db_path)}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(pages)")]
    title_col = "title" if "title" in cols else ("name" if "name" in cols else None)
    path_col = "path" if "path" in cols else None
    pos_col = "position" if "position" in cols else None
    if not title_col or not path_col or not pos_col:
        raise SystemExit("unexpected pages schema: " + ",".join(cols))
    where = ""
    if "parent_id" in cols:
        where = " WHERE parent_id IS NULL OR parent_id = ''"
    sql = (
        f"SELECT {pos_col}, {path_col}, {title_col} FROM pages{where} "
        f"ORDER BY {pos_col}, {title_col}"
    )
    rows = conn.execute(sql).fetchall()
    if not rows and "parent_id" in cols:
        sql = (
            f"SELECT {pos_col}, {path_col}, {title_col} FROM pages "
            f"WHERE instr({path_col}, '/') = 0 "
            f"ORDER BY {pos_col}, {title_col}"
        )
        rows = conn.execute(sql).fetchall()
        print("note: no parent_id-null rows; using top-level paths")
    out = []
    for pos, path, title in rows:
        out.append((str(pos), str(path or ""), str(title or "")))
    return out


def _print(label: str, rows: list[tuple[str, str, str]]) -> None:
    print(f"{label} count={len(rows)}")
    for i, (pos, path, title) in enumerate(rows, 1):
        print(f"{i:02d}|pos={pos}|path={path}|title={title}")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: Dump-PkmSidebar.py LOCAL_DB [ORIGIN_DB]")
        return 2
    local = sys.argv[1]
    if not os.path.isfile(local):
        print("NO_LOCAL_DB")
        return 1
    local_rows = _roots(local)
    _print("local_sidebar", local_rows)
    if len(sys.argv) < 3:
        return 0
    origin = sys.argv[2]
    if not os.path.isfile(origin):
        print("NO_ORIGIN_DB")
        return 1
    origin_rows = _roots(origin)
    _print("origin_sidebar", origin_rows)
    local_paths = [r[1] for r in local_rows]
    origin_paths = [r[1] for r in origin_rows]
    print("== order_compare ==")
    if local_paths == origin_paths:
        print("PATH_ORDER_MATCH")
    else:
        print("PATH_ORDER_MISMATCH")
        n = max(len(local_paths), len(origin_paths))
        for i in range(n):
            a = local_paths[i] if i < len(local_paths) else "<missing>"
            b = origin_paths[i] if i < len(origin_paths) else "<missing>"
            mark = "ok" if a == b else "DIFF"
            print(f"{i+1:02d}|{mark}|local={a}|origin={b}")
        local_set, origin_set = set(local_paths), set(origin_paths)
        extra = sorted(local_set - origin_set)
        missing = sorted(origin_set - local_set)
        if extra:
            print("local_not_on_origin", "|".join(extra))
        if missing:
            print("origin_not_local", "|".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
