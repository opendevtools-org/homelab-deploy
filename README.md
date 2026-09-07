# Homelab deploy (Hub + PKM)

Docker Compose package. Images on `ghcr.io/opendevtools-org`.

Needs Docker Compose v2 and access to `ghcr.io`.

**Backend** (server APIs) and **frontend** (web clients) are **two Compose projects**, same split as a local homelab stack:

| Project | File | Where | Role |
|---------|------|--------|------|
| `homelab-backend` | `docker-compose.backend.yml` | server | Hub Platform API + PKM API |
| | `docker-compose.yml` | server | alias of `docker-compose.backend.yml` |
| | `docker-compose.lan.yml` or `.local.yml` | server | API host ports (pick one) |
| | `docker-compose.config.yml` | server | one-time PKM data ownership |
| | `docker-compose.apps.yml` | server | extra **backends** (Market plugins) |
| `homelab-frontend` | `docker-compose.frontend.yml` | same host as APIs | Hub UI + PKM UI (joins `homelab_default`) |
| | `docker-compose.frontend.lan.yml` or `.frontend.local.yml` | same host or device | UI host ports |
| | `docker-compose.frontend.remote.yml` | device only | proxy to a remote server |

Run them with **separate** `docker compose` commands. Do not combine backend and frontend `-f` files into one `up`.

Scripts: PowerShell (`.ps1`) and Bash (`.sh`) are equivalent.

## Flat install — server (APIs)

```bash
git clone https://github.com/opendevtools-org/homelab-deploy.git
cd homelab-deploy
cp .env.example .env   # Windows: copy .env.example .env
# fill secrets in .env

docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml up -d
```

Localhost: swap `lan` for `local`. Do not combine both. `docker-compose.yml` is an alias of `docker-compose.backend.yml`.

| | |
|--|--|
| Hub API | http://SERVER:8090 |
| PKM API | http://SERVER:8001 |

## Flat install — web clients (same host)

Start the backend first (it creates `homelab_default`). Nginx proxies to `hub-platform` and `pkm-backend` on that network — no extra overlay and no `host.docker.internal`.

```bash
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml up -d
```

## Flat install — web clients (other devices)

On a machine that does **not** run the APIs, set the server URLs and add the remote overlay:

```bash
# HUB_API_UPSTREAM=http://SERVER:8090
# PKM_API_UPSTREAM=http://SERVER:8001
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.remote.yml -f docker-compose.frontend.lan.yml up -d
```

| | |
|--|--|
| Hub UI | http://DEVICE:3080 |
| PKM UI | http://DEVICE:3030 |

Login: `HUB_ADMIN_*` from `.env`. Create users under Utenti. Data in `./data/hub` and `./data/pkm` (gitignored) on the **server**.

## LAN HTTPS (clipboard / paste)

Browsers allow clipboard paste of images only in a **secure context**: `localhost` or **HTTPS**. A VPN or LAN URL such as `http://10.0.0.10:3030` is not a secure context, so paste fails even though the rest of the UI works.

Set LAN names in `.env` (and point them at the server with DNS or a client `hosts` file):

```text
HUB_HOSTNAME=hub.home.arpa
PKM_HOSTNAME=pkm.home.arpa
PUBLIC_PKM_URL=https://pkm.home.arpa/
PUBLIC_PKM_URL_HTTP=http://192.168.1.10:3030/
HUB_COOKIE_SECURE=true
```

Then add the Caddy overlay when starting the web clients (binds host ports 80 and 443):

```bash
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml \
  -f docker-compose.https.yml up -d
```

Site instance: same overlay as `-f docker-compose.https.yml` (copied to the site root). `Update-HomelabUpstream --start` / `-Start` includes it automatically when both hostnames are set.

Caddy uses a local CA (`tls internal`). Trust it once on each client:

```bash
docker exec pkm-https cat /data/caddy/pki/authorities/local/root.crt
```

Or replace `tls internal` in `Caddyfile` with a certificate you already trust. After changing `PUBLIC_PKM_URL`, recreate the backend as well.

Direct HTTP on `:3080` / `:3030` still works; use the HTTPS names for paste.

## Code overrides

Put patches in `overrides/<service>/` and recreate the container. No image rebuild. See [`overrides/README.md`](./overrides/README.md).

| Folder | Drop |
|--------|------|
| `overrides/pkm-backend/` | `sitecustomize.py` (loaded via `PYTHONPATH=/overrides`) |
| `overrides/hub-platform/` | `sitecustomize.py` |
| `overrides/hub-frontend/` | `default.conf` (optional nginx template) |
| `overrides/pkm-frontend/` | `default.conf` |

Site instance: the same folders live at the site root (`./overrides`), not inside `upstream/`. Compose uses `--project-directory .` so the mounts hit the site copies.

## Community plugins (Hub Market)

Public plugins live in [`opendevtools-org/hub-community-plugins`](https://github.com/opendevtools-org/hub-community-plugins).

- **Backend:** `plugins/<id>/docker-compose.backend.yml` — Market copies this into `docker-compose.apps.yml` on the server.
- **Web client:** `plugins/<id>/docker-compose.frontend.yml` — run on a device with `*_API_UPSTREAM` pointing at the server.

From Hub `/market`, **Installa** starts the plugin backend on the Platform server and opens the web client in that Hub (`/p/{id}/`). Merge the plugin’s `.env.example` into `.env` if it has one.

To test a plugin **before** publishing, clone `hub-community-plugins`, edit `catalog.json` + `plugins/<id>/`, then set in `.env`:

```text
HUB_MARKET_PLUGINS_HOST=./community-plugins
```

Recreate Platform. Market shows a “catalogo locale” banner when that folder has `catalog.json`. Leave the variable unset (or point at the empty `.market-plugins-local`) for the GitHub catalog.

Upgrade (flat, server):

```bash
git pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml up -d
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml pull
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml up -d
# If HUB_HOSTNAME and PKM_HOSTNAME are set, also add -f docker-compose.https.yml
```

## Site instance

Your `data/` and apps stay in your git remote. Product code lives in submodule `upstream/`.

### Convert — `New-HomelabSite`

```bash
chmod +x New-HomelabSite.sh Update-HomelabUpstream.sh
./New-HomelabSite.sh --site-repo https://github.com/ORG/REPO.git --push --start
```

```powershell
.\New-HomelabSite.ps1 -SiteRepo https://github.com/ORG/REPO.git -Push -Start
```

| Flag (bash / PowerShell) | Default | Effect |
|------|---------|--------|
| `--site-repo` / `-SiteRepo` | — | Your remote. Required unless skip-git. |
| `--branch` / `-Branch` | `homelab` | Orphan branch on that remote. |
| `--target-dir` / `-TargetDir` | script folder | Folder to convert. |
| `--upstream-url` / `-UpstreamUrl` | this repo on GitHub | Submodule URL. |
| `--ports` / `-Ports` `lan\|local` | `lan` | Ports overlay on start. |
| `--push` / `-Push` | off | Push branch after commit. |
| `--start` / `-Start` | off | Compose pull + up (includes apps). |
| `--skip-git` / `-SkipGit` | off | Files + submodule only. |
| `--skip-commit` / `-SkipCommit` | off | Skip local commit. |

Layout after convert:

```
./upstream/
./data/
./.env
./docker-compose.config.yml
./docker-compose.apps.yml
./Update-HomelabUpstream.sh
./Update-HomelabUpstream.ps1
./Backup-DataGit.sh
./Backup-DataGit.ps1
./Pull-DataGit.sh
./Pull-DataGit.ps1
./Register-DataGitBackup.sh
./Register-DataGitBackupTask.ps1
./Register-DataGitPull.sh
./Register-DataGitPullTask.ps1
./Reindex-PkmFromDisk.sh
./Reindex-PkmFromDisk.ps1
./Caddyfile
./docker-compose.https.yml
./overrides/
./.gitignore.upstream
./.gitignore.custom
./.gitignore
```

Start:

```bash
docker compose --project-directory . \
  -f upstream/docker-compose.backend.yml \
  -f upstream/docker-compose.lan.yml \
  -f docker-compose.config.yml \
  -f docker-compose.apps.yml up -d
docker compose --project-directory . \
  -f upstream/docker-compose.frontend.yml \
  -f upstream/docker-compose.frontend.lan.yml up -d
# LAN HTTPS (clipboard): add -f docker-compose.https.yml when HUB_HOSTNAME and PKM_HOSTNAME are set
```

`--project-directory .` so volumes hit this folder’s `data/`.

First start on a new host:

1. `git submodule update --init --recursive upstream` (required: base compose lives in `upstream/`).
2. Copy `.env.example` to `.env` and set `PLATFORM_SERVICE_TOKEN`, `HUB_JWT_SECRET`, and `JWT_SECRET`.
3. If Compose reports a container name conflict (`home-hub`, `pkm-backend`, `pkm-frontend`), remove the leftover containers, then `up` again.
4. If `pkm-backend` restarts with a permission error on `/app/data/bookmarks`, the data dir is not owned by `PUID`/`PGID`. Recreate with `docker-compose.config.yml` included, or `chown -R 1000:1000 data/pkm` on a Linux host (use the same ids as `.env`).
5. From other machines, set `PUBLIC_PKM_URL` to the server IP or hostname, not `127.0.0.1`. For clipboard paste of images, use the LAN HTTPS overlay below.

Do not bind-mount whole Platform `main.py` / `config.py` into `docker-compose.apps.yml`. Prefer a new image (`HOMELAB_VERSION` / `PKM_VERSION`) or a small `overrides/*/sitecustomize.py` / `default.conf`.

### Update product — `Update-HomelabUpstream`

No flags: only `git pull` in `upstream/`.

```bash
./Update-HomelabUpstream.sh
./Update-HomelabUpstream.sh --commit --push --start
```

```powershell
.\Update-HomelabUpstream.ps1
.\Update-HomelabUpstream.ps1 -Commit -Push -Start
```

| Flag (bash / PowerShell) | Default | Effect |
|------|---------|--------|
| *(none)* | — | Pull in `upstream/` only. |
| `--commit` / `-Commit` | off | Commit submodule pointer. |
| `--push` / `-Push` | off | Rebase onto origin, then push (implies commit). |
| `--start` / `-Start` | off | Compose pull + up (includes apps), then PKM import from disk. |
| `--ports` / `-Ports` | `lan` | Ports overlay with start. |

### Daily data backup — `Backup-DataGit`

Site instances only (`data/` is versioned). `New-HomelabSite` initializes a layered gitignore: `.gitignore.upstream` tracks this package, `.gitignore.custom` holds **only** site extras, and `.gitignore` is generated from both (do not edit it). `Update-HomelabUpstream` refreshes the upstream layer, so custom rules survive product updates. Commits and pushes `data/`, `docker-compose.apps.yml`, `overrides/`, and `README.md`. If someone else pushed to the same branch, the script tries `pull --rebase --autostash`, then falls back to merge.

For `data/hub/platform.db` and `data/pkm/pkm.db`, Backup/Pull run a three-way SQLite row merge (`Merge-SqliteGitConflict.py`): rows present on only one side are kept; when the same row changed on both sides, the later `updated_at` (or equivalent timestamp) wins. FTS, locks, and runtime state are not merged; PKM rebuilds them on reindex. The merged file replaces the canonical db only after integrity and foreign-key checks. If Python or the helper is missing, or schemas differ, the conservative fallback applies: remote stays canonical and the local copy is saved next to it:

```text
filename.local-conflict.HOSTNAME.20260820-143000.md
```

Those conflict copies are committed and pushed, so local edits are not dropped silently.

Optional HTTPS auth in `.env` (not committed): `HOMELAB_GIT_USERNAME` and `HOMELAB_GIT_PAT`. If the PAT is set, the scripts use HTTP Basic against `origin` without changing the Git remote. Requires an HTTPS origin. Host git credentials (SSH or credential helper) still work when the PAT is empty.

Optional notify webhook: `HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL`. Logs under `logs/`.

Register a daily schedule (default `00:05`, change with `-Time` / `--time`):

```powershell
.\Register-DataGitBackupTask.ps1 -Time 00:05
.\Backup-DataGit.ps1
```

```bash
chmod +x Backup-DataGit.sh Register-DataGitBackup.sh
./Register-DataGitBackup.sh --time 00:05
./Backup-DataGit.sh
```

Unregister Linux cron: `./Register-DataGitBackup.sh --uninstall`.

### Two servers — `Pull-DataGit`

If both machines can receive edits, schedule Git on both:

- primary: `Backup-DataGit.sh` or `Backup-DataGit.ps1`
- standby: `Pull-DataGit.sh` or `Pull-DataGit.ps1`

The standby pull first commits local changes in `data/`, `docker-compose.apps.yml`, and `README.md`, then syncs with `origin` and pushes. Edits made on either server reach the other on the next run.

After a successful Backup or Pull, the scripts restart the `pkm-backend` container and call the same APIs as **Import from disk** / **Sync from disk** in the UI (pages, files, PDFs, bookmarks). PKM is down for a few seconds during the restart. Skip with `HOMELAB_PKM_REINDEX_AFTER_SYNC=false` in `.env`, or run `./Reindex-PkmFromDisk.sh` / `.\Reindex-PkmFromDisk.ps1` by itself.

```powershell
.\Register-DataGitPullTask.ps1 -Time 00:10
.\Pull-DataGit.ps1
```

```bash
chmod +x Pull-DataGit.sh Register-DataGitPull.sh
./Register-DataGitPull.sh --time 00:10
./Pull-DataGit.sh
```

This is scheduled Git sync, not a realtime cluster. Shorten the interval if you want less delay, and avoid editing the same file on both servers at once.

### Clone elsewhere

```bash
git clone -b homelab --recurse-submodules https://github.com/ORG/REPO.git
cd REPO
cp .env.example .env
# fill secrets, then compose up as above
```

## Images

`homelab-hub`, `homelab-platform`, `pkm-backend`, `pkm-frontend` under `ghcr.io/opendevtools-org`.

While in test/dev, publish overwrites only `:latest` (`HOMELAB_VERSION` / `PKM_VERSION` default `latest`). For a real release later, publish with an explicit semver (e.g. `1.0.0`) and pin that in `.env`.

## License

OpenDevTools End-User License — internal run/review; no redistribution of images or reuse of the implementation without agreement.
