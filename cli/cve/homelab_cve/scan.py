from __future__ import annotations

import os
import subprocess
import tarfile
import zipfile
from io import BytesIO

from .jars import JarMatch, inspect_jar, is_target_jar, read_version, version_from_filename


def _docker_exec(container: str, arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["docker", "exec", container, *arguments], capture_output=True, check=False)


def _read_jar_matches(paths: list[str], container: str, target_name: str) -> list[JarMatch]:
    matches: list[JarMatch] = []
    for path in paths:
        filename_version = version_from_filename(path)
        if filename_version:
            matches.append(JarMatch(path, None, filename_version, "filename"))
            continue
        result = _docker_exec(container, ["cat", path])
        if result.returncode != 0:
            continue
        data = result.stdout
        try:
            archive = zipfile.ZipFile(BytesIO(data))
            with archive:
                version, source = read_version(archive, path)
        except zipfile.BadZipFile:
            version, source = version_from_filename(path), "filename"
        matches.append(JarMatch(path, None, version, source))
        matches.extend(inspect_jar(data, target_name, path))
    return matches


def _check_with_archive_listing(
    container: str, target_name: str, root: str, on_match=None
) -> list[JarMatch] | None:
    script = r"""
command -v unzip >/dev/null 2>&1 || exit 127
find "$2" -type f \( -name '*.jar' -o -name '*.war' -o -name '*.ear' \) -print 2>/dev/null |
while IFS= read -r archive; do
    case "$(basename "$archive")" in
        *$1*.jar) printf 'MATCH\tDIRECT\t%s\n' "$archive" ;;
    esac
    unzip -l "$archive" 2>/dev/null |
    grep -iF -- "$1" |
    while read -r size date time entry; do
        case "$(basename "$entry")" in
            *.jar) printf 'MATCH\t%s\t%s\n' "$archive" "$entry" ;;
        esac
    done
done
"""
    process = subprocess.Popen(
        ["docker", "exec", "-i", container, "sh", "-s", "--", target_name, root],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    process.stdin.write(script.encode())
    process.stdin.close()

    matches: list[JarMatch] = []
    for raw_line in process.stdout:
        line = raw_line.decode(errors="replace").rstrip("\r\n")
        if not line.startswith("MATCH\t"):
            continue
        _, archive_path, entry_path = line.split("\t", maxsplit=2)
        if archive_path == "DIRECT":
            direct = _read_jar_matches([entry_path], container, target_name)
            matches.extend(direct)
            if on_match:
                for match in direct:
                    on_match(match)
            continue
        if not is_target_jar(entry_path, target_name):
            continue
        filename_version = version_from_filename(entry_path)
        if filename_version:
            match = JarMatch(entry_path, archive_path, filename_version, "filename")
            matches.append(match)
            if on_match:
                on_match(match)
            continue
        extracted = _docker_exec(container, ["unzip", "-p", archive_path, entry_path])
        if extracted.returncode != 0:
            continue
        try:
            nested_archive = zipfile.ZipFile(BytesIO(extracted.stdout))
            with nested_archive:
                version, source = read_version(nested_archive, entry_path)
        except zipfile.BadZipFile:
            version, source = version_from_filename(entry_path), "filename"
        match = JarMatch(entry_path, archive_path, version, source)
        matches.append(match)
        if on_match:
            on_match(match)

    return_code = process.wait()
    if return_code:
        return None
    return matches if matches else None


def _check_with_container_shell(container: str, target_name: str) -> list[JarMatch] | None:
    result = _docker_exec(container, ["sh", "-c", "find / -type f -name '*.jar' -print 2>/dev/null"])
    if result.returncode != 0:
        return None
    paths = [
        path
        for path in result.stdout.decode(errors="replace").splitlines()
        if is_target_jar(path, target_name)
    ]
    return _read_jar_matches(paths, container, target_name)


def check_jar_version(
    container: str,
    jar: str,
    root: str = "/",
    on_match=None,
) -> list[JarMatch]:
    target_name = os.path.basename(jar)
    matches: list[JarMatch] = []
    archive_matches = _check_with_archive_listing(container, target_name, root, on_match=on_match)
    if archive_matches is not None:
        return archive_matches
    shell_matches = _check_with_container_shell(container, target_name)
    if shell_matches is not None:
        return shell_matches

    process = subprocess.Popen(
        ["docker", "export", container],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    with tarfile.open(fileobj=process.stdout, mode="r|") as snapshot:
        for member in snapshot:
            if not member.isfile() or not is_target_jar(member.name, target_name):
                continue
            extracted = snapshot.extractfile(member)
            if extracted is None:
                continue
            path = "/" + member.name.lstrip("/")
            data = extracted.read()
            try:
                archive = zipfile.ZipFile(BytesIO(data))
                with archive:
                    version, source = read_version(archive, path)
            except zipfile.BadZipFile:
                version, source = version_from_filename(path), "filename"
            match = JarMatch(path, None, version, source)
            matches.append(match)
            if on_match:
                on_match(match)
            matches.extend(inspect_jar(data, target_name, path))
    stderr = process.stderr.read() if process.stderr else b""
    return_code = process.wait()
    if return_code:
        raise subprocess.CalledProcessError(return_code, process.args, stderr=stderr)
    return matches
