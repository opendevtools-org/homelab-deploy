from __future__ import annotations

import os
import re
import zipfile
from io import BytesIO

from .models import JarMatch

VERSION_PATTERN = re.compile(r"(?:^|[-_.])v?([0-9]+(?:\.[0-9]+)+(?:[-+][0-9A-Za-z.-]+)?)")


def manifest_value(manifest: str, key: str) -> str | None:
    unfolded = re.sub(r"\r?\n[ ]", "", manifest)
    prefix = f"{key}:"
    for line in unfolded.splitlines():
        if line.startswith(prefix) and line[len(prefix) :].strip():
            return line[len(prefix) :].strip()
    return None


def version_from_filename(filename: str) -> str | None:
    match = VERSION_PATTERN.search(os.path.basename(filename))
    return match.group(1) if match else None


def is_target_jar(filename: str, target_name: str) -> bool:
    filename = os.path.basename(filename).lower()
    target_name = os.path.basename(target_name).lower()
    if target_name.endswith(".jar"):
        target_name = target_name[:-4]
    return filename == f"{target_name}.jar" or (
        filename.startswith(f"{target_name}-") and filename.endswith(".jar")
    )


def read_version(archive: zipfile.ZipFile, filename: str) -> tuple[str | None, str | None]:
    try:
        manifest = archive.read("META-INF/MANIFEST.MF").decode("utf-8", errors="replace")
    except KeyError:
        manifest = ""
    for attribute in ("Implementation-Version", "Bundle-Version", "Specification-Version"):
        version = manifest_value(manifest, attribute)
        if version:
            return version, f"manifest:{attribute}"
    for entry in archive.namelist():
        if entry.startswith("META-INF/maven/") and entry.endswith("/pom.properties"):
            properties = archive.read(entry).decode("utf-8", errors="replace")
            match = re.search(r"(?m)^version\s*=\s*(.+)$", properties)
            if match:
                return match.group(1).strip(), f"{entry}:version"
    version = version_from_filename(filename)
    return version, "filename" if version else None


def inspect_jar(data: bytes, target_name: str, containing_jar: str | None = None) -> list[JarMatch]:
    matches: list[JarMatch] = []
    try:
        archive = zipfile.ZipFile(BytesIO(data))
    except zipfile.BadZipFile:
        return matches
    with archive:
        for entry in archive.infolist():
            if entry.is_dir() or not entry.filename.lower().endswith(".jar"):
                continue
            nested_data = archive.read(entry)
            if is_target_jar(entry.filename, target_name):
                try:
                    nested_archive = zipfile.ZipFile(BytesIO(nested_data))
                    with nested_archive:
                        version, source = read_version(nested_archive, entry.filename)
                except zipfile.BadZipFile:
                    version, source = version_from_filename(entry.filename), "filename"
                matches.append(JarMatch(entry.filename, containing_jar, version, source))
            matches.extend(inspect_jar(nested_data, target_name, entry.filename))
    return matches
