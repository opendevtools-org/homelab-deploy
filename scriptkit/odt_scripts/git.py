"""Clone or update a git repo. Optional HTTPS token from the environment."""

from __future__ import annotations

from pathlib import Path
from urllib.parse import quote, urlparse, urlunparse

from .env import first_env
from .process import run


def _authed_url(url: str, *, username: str, token: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not token:
        return url
    user = quote(username or "git", safe="")
    secret = quote(token, safe="")
    netloc = f"{user}:{secret}@{parsed.hostname}"
    if parsed.port:
        netloc = f"{netloc}:{parsed.port}"
    return urlunparse(parsed._replace(netloc=netloc))


def clone_or_update(
    url: str,
    dest: Path,
    *,
    branch: str = "",
    token: str = "",
    username: str = "",
) -> int:
    """Clone ``url`` into ``dest``, or fetch if ``dest`` already has a ``.git``.

    Token is taken from ``token`` or ``GIT_TOKEN`` / ``HOMELAB_GIT_PAT``.
    Never prints the token.
    """
    dest = Path(dest)
    secret = token or first_env("GIT_TOKEN", "HOMELAB_GIT_PAT")
    user = username or first_env("GIT_USERNAME", "HOMELAB_GIT_USERNAME", default="git")
    remote = _authed_url(url, username=user, token=secret)
    if (dest / ".git").is_dir():
        argv = ["git", "-C", str(dest), "fetch", "--depth", "1", "--progress", "origin"]
        if branch:
            argv.append(branch)
        result = run(argv)
        if result.returncode != 0:
            return result.returncode
        if branch:
            return run(["git", "-C", str(dest), "checkout", branch]).returncode
        return 0
    dest.parent.mkdir(parents=True, exist_ok=True)
    argv = ["git", "clone", "--depth", "1", "--progress"]
    if branch:
        argv.extend(["--branch", branch])
    argv.extend([remote, str(dest)])
    return run(argv).returncode
