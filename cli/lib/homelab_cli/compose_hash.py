from __future__ import annotations

import hashlib
import os


def calculate_file_hash(file_path: str) -> str:
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as handle:
        for byte_block in iter(lambda: handle.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()


def check_compose_file_changes(temp_file_path: str) -> tuple[bool, str | None]:
    """Return (changed, current_hash). First run records the hash and returns False."""
    hash_file_path = temp_file_path.replace(".yml", "-hash.txt")
    if not os.path.exists(temp_file_path):
        return False, None

    current_hash = calculate_file_hash(temp_file_path)
    if not os.path.exists(hash_file_path):
        with open(hash_file_path, "w", encoding="utf-8") as handle:
            handle.write(current_hash)
        return False, current_hash

    with open(hash_file_path, "r", encoding="utf-8") as handle:
        previous_hash = handle.read().strip()

    if current_hash != previous_hash:
        with open(hash_file_path, "w", encoding="utf-8") as handle:
            handle.write(current_hash)
        return True, current_hash
    return False, current_hash
