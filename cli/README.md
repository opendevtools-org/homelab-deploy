# Product CLIs

Generic tools shipped with this package. They have **no company hostnames, registries, or product paths**.

| Path | Role |
|------|------|
| `cli/lib/homelab_cli/` | Library: Docker name lookup, markdown command blocks, compose hash, GitHub-compatible REST |
| `cli/cve/` | CVE / nested-JAR inspector. Extra libraries and default scan root come from **JSON config**, not from code |

Site instance (after `New-HomelabSite`): run from the site root against the submodule:

```bash
python upstream/cli/cve/main.py --config ./cve-sources.json check-fixed-cve --library openssl --version 3.0.16
```

Copy `upstream/cli/cve/config/sources.example.json` to `./cve-sources.json` on the site and edit URLs or `default_scan_root`. That file stays in the **site** git remote, not in this product repo.

A company wrapper CLI (defaults, extra subcommands) should import `homelab_cli` / `homelab_cve` and keep company names out of the library.
