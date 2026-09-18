"""Align SSO bounce next to the Hub request host without rebuilding Platform.

When Hub is opened on localhost, rewrite next away from LAN names so PKM
opens on the same host. Loaded via PYTHONPATH=/overrides (sitecustomize).
"""

from __future__ import annotations


def _patch_safe_launch(mod) -> None:
    if getattr(mod, "_hub_same_host_rewrite", False):
        return
    orig = getattr(mod, "_safe_launch_next", None)
    if orig is None:
        return

    from urllib.parse import urlparse

    loopback = frozenset({"localhost", "127.0.0.1", "::1"})

    def _safe_launch_next(next_url, prefer_host=None, app_id=None, **kwargs):
        raw = (next_url or "").strip()
        pref = (prefer_host or "").lower().split(":")[0]
        parsed = urlparse(raw)
        host = (parsed.hostname or "").lower()
        if pref in loopback and host and host not in loopback:
            port = parsed.port or 3030
            if (app_id or "").strip().lower() == "pkm":
                try:
                    from app.config import settings

                    port = int(settings.builtin_pkm_port)
                except Exception:
                    port = 3030
            raw = parsed._replace(scheme="http", netloc=f"{pref}:{port}").geturl()
        try:
            return orig(raw, prefer_host=prefer_host, app_id=app_id, **kwargs)
        except TypeError:
            return orig(raw, prefer_host=prefer_host)

    mod._safe_launch_next = _safe_launch_next
    mod._hub_same_host_rewrite = True


def _install() -> None:
    import builtins

    real_import = builtins.__import__

    def _import(name, globals=None, locals=None, fromlist=(), level=0):
        mod = real_import(name, globals, locals, fromlist, level)
        target = None
        if name == "app.main" or name.endswith(".main"):
            target = mod
        elif name == "app" and fromlist and "main" in fromlist:
            target = getattr(mod, "main", None)
        if target is not None and hasattr(target, "_safe_launch_next"):
            _patch_safe_launch(target)
        return mod

    builtins.__import__ = _import


_install()
