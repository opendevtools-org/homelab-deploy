from __future__ import annotations

import subprocess


def get_existing_container(name: str) -> str:
    result = subprocess.run(
        ["docker", "ps", "-a", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    names = result.stdout.splitlines()
    if name in names:
        return name
    lower_name = name.lower()
    for container_name in names:
        if container_name.lower() == lower_name:
            return container_name
    return name
