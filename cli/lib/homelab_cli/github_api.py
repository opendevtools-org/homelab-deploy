from __future__ import annotations

import base64
import json
import os
import re
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def api_headers(
    token_env: str = "GITHUB_TOKEN",
    username_env: str = "GITHUB_USERNAME",
) -> dict[str, str]:
    token = os.getenv(token_env) or os.getenv("HOMELAB_GIT_PAT") or ""
    if not token:
        raise RuntimeError(
            f"Set {token_env} (or HOMELAB_GIT_PAT) before calling the GitHub API."
        )
    username = os.getenv(username_env) or os.getenv("HOMELAB_GIT_USERNAME") or "x-access-token"
    authorization = base64.b64encode(f"{username}:{token}".encode()).decode()
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Basic {authorization}",
        "Content-Type": "application/json",
    }


def api_url(repository: str, resource: str) -> str:
    parsed = urlsplit(repository)
    repository_path = parsed.path.strip("/").removesuffix(".git")
    if parsed.scheme != "https" or not parsed.netloc or repository_path.count("/") != 1:
        raise ValueError(f"Unsupported repository URL: {repository}")
    host = parsed.netloc.lower()
    if host in ("github.com", "www.github.com"):
        return f"https://api.github.com/repos/{repository_path}/git/{resource}"
    return f"{parsed.scheme}://{parsed.netloc}/api/v3/repos/{repository_path}/git/{resource}"


def github_request(
    repository: str,
    resource: str,
    method: str = "GET",
    body: dict | None = None,
    token_env: str = "GITHUB_TOKEN",
    username_env: str = "GITHUB_USERNAME",
) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = Request(
        api_url(repository, resource),
        data=data,
        headers=api_headers(token_env=token_env, username_env=username_env),
        method=method,
    )
    with urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode())


def version_from_tag(tag: str) -> str:
    match = re.fullmatch(r"v?(\d+(?:\.\d+)+)(?:[_-].+)?", tag)
    if not match:
        raise ValueError(
            f"Unsupported tag '{tag}'. Expected a version tag such as v1.2.3 or v1.2.3_202601."
        )
    return match.group(1)


def tag_commit(
    repository: str,
    tag: str,
    token_env: str = "GITHUB_TOKEN",
    username_env: str = "GITHUB_USERNAME",
) -> str:
    try:
        reference = github_request(
            repository,
            f"ref/tags/{tag}",
            token_env=token_env,
            username_env=username_env,
        )
        target = reference["object"]
        while target["type"] == "tag":
            target = github_request(
                repository,
                f"tags/{target['sha']}",
                token_env=token_env,
                username_env=username_env,
            )["object"]
        if target["type"] != "commit":
            raise ValueError(f"Tag '{tag}' does not point to a commit in {repository}")
        return target["sha"]
    except HTTPError as error:
        if error.code == 404:
            raise ValueError(f"Tag '{tag}' does not exist in {repository}") from error
        raise RuntimeError(
            f"Cannot read tag '{tag}' in {repository}: HTTP {error.code}"
        ) from error
