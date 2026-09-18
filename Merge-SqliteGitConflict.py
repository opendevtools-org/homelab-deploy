#!/usr/bin/env python3
import argparse
import shutil
import sqlite3
from pathlib import Path


DATABASE_POLICIES = {
    "platform": {
        "plugin_opt_out": None,
        "plugins": "updated_at",
        "sources": None,
        "users": None,
        "user_app_grants": None,
    },
    "pkm": {
        "bookmarks": "updated_at",
        "hosted_files": None,
        "pages": "updated_at",
        "pdf_documents": "indexed_at",
        "users": None,
        "file_drive_links": "synced_at",
    },
}

# Union local and remote: never delete a user or grant that exists on one side.
NON_DESTRUCTIVE_TABLES = frozenset({"users", "user_app_grants"})


def quote_identifier(value):
    return '"' + value.replace('"', '""') + '"'


def open_readonly(path):
    return sqlite3.connect(f"file:{Path(path).resolve()}?mode=ro", uri=True)


def check_integrity(connection, label):
    result = connection.execute("PRAGMA integrity_check").fetchone()
    if not result or result[0] != "ok":
        raise RuntimeError(f"{label} database integrity check failed: {result}")


def table_definition(connection, table):
    columns = connection.execute(
        f"PRAGMA table_info({quote_identifier(table)})"
    ).fetchall()
    if not columns:
        raise RuntimeError(f"required table is missing: {table}")
    names = [column[1] for column in columns]
    primary_key = [
        column[1] for column in sorted(columns, key=lambda column: column[5]) if column[5]
    ]
    if not primary_key:
        raise RuntimeError(f"table has no primary key: {table}")
    return names, primary_key


def read_rows(connection, table, columns, primary_key):
    column_sql = ", ".join(quote_identifier(column) for column in columns)
    indexes = [columns.index(column) for column in primary_key]
    rows = {}
    for row in connection.execute(
        f"SELECT {column_sql} FROM {quote_identifier(table)}"
    ):
        key = tuple(row[index] for index in indexes)
        rows[key] = row
    return rows


def choose_row(base, local, remote, timestamp_index, preserve_rows=False):
    if preserve_rows:
        if local is None:
            return remote
        if remote is None:
            return local
    if local == remote:
        return local
    if local == base:
        return remote
    if remote == base:
        return local
    if local is not None and remote is not None and timestamp_index is not None:
        local_timestamp = local[timestamp_index] or ""
        remote_timestamp = remote[timestamp_index] or ""
        if local_timestamp > remote_timestamp:
            return local
    return remote


def table_exists(connection, table):
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?",
        (table,),
    ).fetchone()
    return bool(row)


def merge_table(output, base, local, remote, table, timestamp_column):
    if not all(table_exists(db, table) for db in (base, local, remote)):
        return 0
    definitions = [table_definition(db, table) for db in (base, local, remote)]
    if definitions[0] != definitions[1] or definitions[0] != definitions[2]:
        raise RuntimeError(f"table schema differs between database versions: {table}")

    columns, primary_key = definitions[0]
    if timestamp_column is not None and timestamp_column not in columns:
        raise RuntimeError(f"timestamp column is missing from {table}: {timestamp_column}")
    timestamp_index = columns.index(timestamp_column) if timestamp_column else None
    base_rows = read_rows(base, table, columns, primary_key)
    local_rows = read_rows(local, table, columns, primary_key)
    remote_rows = read_rows(remote, table, columns, primary_key)

    quoted_columns = ", ".join(quote_identifier(column) for column in columns)
    placeholders = ", ".join("?" for _ in columns)
    non_key_columns = [column for column in columns if column not in primary_key]
    conflict_columns = ", ".join(quote_identifier(column) for column in primary_key)
    if non_key_columns:
        assignments = ", ".join(
            f"{quote_identifier(column)} = excluded.{quote_identifier(column)}"
            for column in non_key_columns
        )
        conflict_action = f"DO UPDATE SET {assignments}"
    else:
        conflict_action = "DO NOTHING"
    upsert_sql = (
        f"INSERT INTO {quote_identifier(table)} ({quoted_columns}) VALUES ({placeholders}) "
        f"ON CONFLICT ({conflict_columns}) {conflict_action}"
    )
    where = " AND ".join(f"{quote_identifier(column)} = ?" for column in primary_key)
    delete_sql = f"DELETE FROM {quote_identifier(table)} WHERE {where}"

    changed = 0
    all_keys = set(base_rows) | set(local_rows) | set(remote_rows)
    for key in all_keys:
        desired = choose_row(
            base_rows.get(key),
            local_rows.get(key),
            remote_rows.get(key),
            timestamp_index,
            preserve_rows=table in NON_DESTRUCTIVE_TABLES,
        )
        if desired == remote_rows.get(key):
            continue
        if desired is None:
            output.execute(delete_sql, key)
        else:
            output.execute(upsert_sql, desired)
        changed += 1
    return changed


def merge_databases(base_path, local_path, remote_path, output_path, database_type):
    policy = DATABASE_POLICIES[database_type]
    base = local = remote = output = None
    try:
        base = open_readonly(base_path)
        local = open_readonly(local_path)
        remote = open_readonly(remote_path)
        for connection, label in ((base, "base"), (local, "local"), (remote, "remote")):
            check_integrity(connection, label)

        shutil.copy2(remote_path, output_path)
        output = sqlite3.connect(output_path)
        output.execute("PRAGMA foreign_keys = OFF")
        output.execute("BEGIN IMMEDIATE")
        changes = {}
        for table, timestamp_column in policy.items():
            count = merge_table(
                output, base, local, remote, table, timestamp_column
            )
            if count:
                changes[table] = count

        foreign_key_errors = output.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_errors:
            raise RuntimeError(
                f"merged database has foreign key errors: {foreign_key_errors[:5]}"
            )
        check_integrity(output, "merged")
        output.commit()
        return changes
    except Exception:
        if output is not None:
            output.rollback()
        raise
    finally:
        for connection in (output, remote, local, base):
            if connection is not None:
                connection.close()


def main():
    parser = argparse.ArgumentParser(description="Merge a three-way SQLite Git conflict")
    parser.add_argument("--type", choices=sorted(DATABASE_POLICIES), required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--local", required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    changes = merge_databases(
        args.base, args.local, args.remote, args.output, args.type
    )
    summary = ", ".join(f"{table}={count}" for table, count in changes.items())
    print(summary or "no logical row changes")


if __name__ == "__main__":
    main()