# Prompt: extract generic fixes from a site server dump

Copy everything below the line into a new agent chat (with this `docker-only` tree open). Drop the dump first; do not skip the ignore / leak rules.

---

You are extracting **product** improvements from a **site instance dump** (a running Hub+PKM install that was patched to make it work).

## Inputs

1. Place the dump under `sugestions/<site-id>-<timestamp>/` in this folder (`homelab-deploy` / `apps/homelab/deploy/docker-only`). That path is gitignored. Never add it to git, never copy it into `opendevtools-org` repos, never commit `.env`, `data/`, tokens, or hostnames of the customer site.
2. The **generic product** is this directory (not the dump). If a file exists both in the dump root and in `dump/upstream/`, treat:
   - `dump/upstream/` = product they had at convert/update time
   - dump root = site overlay (scripts copied to the site + local patches)
   - current tree = product **now**

## Goal

Port only fixes that **any** site would hit. If the dump hardcodes a name, IP, plugin, or folder slug, keep the **behavior** and **parameterize** it.

## Diff procedure (mandatory)

1. List dump-root files vs `dump/upstream/` (what they changed on the box).
2. Hash/diff those against the **current** product files.
3. Classify every delta:

| Class | Action |
|--------|--------|
| Already in current product (Hub/PKM source or compose) | Do not re-import. Tell the operator to pull images / `Update-HomelabUpstream`. |
| Generic bug, hardcoded to this site | Reimplement in product with a general rule (env, suffix pattern, `PUID`/`PGID`, etc.). Add a short test if it is logic. |
| Instance-only | Leave on the site: secrets, hostnames, extra compose services, zip helpers, bind-mount of whole `main.py`/`config.py`, local Dockerfiles that only paper over an old image. |
| Identity leak | Never copy into this tree: personal names, extra lab plugin ids as product defaults, lab monorepo paths, customer wiki slugs. |

## Known patterns (apply the **rule**, not the site names)

- Git/OS duplicate wiki paths: `name-1` next to `name` under `data/pkm/docs`. Product helper: `Normalize-PkmDuplicatePaths.py` (strip only a final `-1` segment, not `ubuntu-22`). Wire through `Pull-DataGit.sh` and `Pull-DataGit.ps1`. Snapshot/restore `pages.position` on canonical keys. Copy the helper in `New-HomelabSite` and `Update-HomelabUpstream` launcher lists.
- Git as root then PKM as `PUID`/`PGID`: `PermissionError` on `data/pkm/bookmarks`. After Backup/Pull on Linux, `mkdir -p bookmarks` and `chown -R` when running as root. First-start also in `docker-compose.config.yml`.
- HTTPS LAN + clipboard: Caddy overlay, `PUBLIC_PKM_URL` https, optional `PUBLIC_PKM_URL_HTTP` for Hub catalog when the browser is still on HTTP. Implement in Hub Platform + compose env, **not** by bind-mounting entire Platform Python files.
- Nginx `X-Forwarded-Proto` / CRLF on `15-apply-code-overrides.sh`: fix Hub/PKM **images** (Dockerfile `sed` of `\r`, `.gitattributes` LF). Do not keep a site `Dockerfile` `FROM …:latest` + `sed` as the product solution.
- Nginx `sub_filter` on minified JS: do **not** ship as default `overrides/*/default.conf`. Fix the frontend source or leave as a documented optional override.

## Implementation rules

- Prefer Hub/PKM source or a small helper script over copying a whole service file from the dump.
- Keep bash and PowerShell behavior aligned when you touch a pair (`.sh` / `.ps1`).
- Document the generic behavior in `README.md` (English). No customer hostnames, no `/opt/…` paths.
- Do not empty `docker-compose.apps.yml` with site bind-mounts of `config.py`/`main.py`.
- After code changes, say whether GHCR republish is required (image vs compose/script only).
- Do not commit or push unless the operator asks. If they ask to publish the compose package, sync this folder to `opendevtools-org/homelab-deploy` with org identity and a leak scan (`rg` for personal/customer strings).

## Output

1. Table: dump delta → class → product file (or “skip” + why).
2. Code/docs for every “generic” row.
3. What the site should **delete** after they update (stale overrides).
4. Tests run (if any) and what was **not** verified.

---
