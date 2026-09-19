# Homelab deploy (Hub + PKM + Guacamole)

Docker Compose package. Images on `ghcr.io/opendevtools-org`.

Needs Docker Compose v2 and access to `ghcr.io`.

**Backend** (server APIs) and **frontend** (web clients) are **two Compose projects**, same split as a local homelab stack:

| Project | File | Where | Role |
|---------|------|--------|------|
| `homelab-backend` | `docker-compose.backend.yml` | server | Hub Platform API + PKM API |
| | `docker-compose.yml` | server | alias of `docker-compose.backend.yml` |
| | `docker-compose.lan.yml` or `.local.yml` | server | API host ports (pick one) |
| | `docker-compose.config.yml` | server | one-shot ownership (`data/pkm` + CLI named volumes) |
| | `docker-compose.custom.yml` | server | optional Hub/PKM image + `cli/` mounts |
| | `docker-compose.apps.yml` | server | extra **backends** (Market plugins; Guacamole is installed here on first start) |
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

docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.custom.yml -f docker-compose.apps.yml pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.custom.yml -f docker-compose.apps.yml up -d
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

On first Platform start, Hub installs **Guacamole** from the community catalog (`HUB_DEFAULT_MARKET_PLUGINS=guacamole`) unless you already uninstalled it. Compose files live only under `data/hub/plugins/guacamole/` (not in the Hub/PKM site compose). Plugin runtime data (`data/hub/plugins/*/data/`, including Guacamole JARs and schema copies) is gitignored. Open it from the Hub catalog (`/p/guacamole/`). Set `HUB_DEFAULT_MARKET_PLUGINS=none` to skip.

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

Or replace `tls internal` in `Caddyfile` with a certificate you already trust. After changing `PUBLIC_PKM_URL` in `.env`, recreate the backend so Platform seed writes the plugin `public_url` from env (`docker compose … up -d --force-recreate`, or `Update-HomelabUpstream --start`). A `up -d` without recreate can keep a stale URL inside the running container.

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

## Extra packages and site CLIs

`docker-compose.custom.yml`, `docker-compose.apps.yml`, `docker/**/Dockerfile`, and `cli/` are **site-owned**. `Update-HomelabUpstream` copies `scriptkit/`, `agent-context/` (except `site/`), `docker/*.example`, and the `*.example.yml` overlays onto the **site root** (not only `upstream/`).

If an older site-root updater only refreshed the submodule, run the copy inside `upstream/` once:

```bash
./upstream/Update-HomelabUpstream.sh
```

```powershell
.\upstream\Update-HomelabUpstream.ps1
```

| Need | Where |
|------|--------|
| Extra OS packages (Java, Maven, …) | Copy `docker/pkm-backend/Dockerfile.example` → `Dockerfile`, then the `build:` snippet from `docker-compose.custom.example.yml` |
| Heavy CLI cache (git, Maven) | Named volumes `site-cli-cache` / `site-cli-home` + one-shot chown in `docker-compose.config.yml` |
| Shared Python helpers | `scriptkit/odt_scripts` (`PYTHONPATH=/app/scriptkit:/overrides`) |
| Your commands | `cli/custom/<name>/` + a PKM launcher under `data/pkm/scripts/<name>/` |
| Extra apps / Market plugins | `docker-compose.apps.yml` |
| Agent notes | `agent-context/` (product) and `agent-context/site/` (instance) |

Do not bind-mount whole Platform `main.py` / `config.py`. Recreate with `--build` after Dockerfile edits.

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
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.custom.yml -f docker-compose.apps.yml pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.custom.yml -f docker-compose.apps.yml up -d
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
./docker-compose.custom.yml
./docker-compose.apps.yml
./docker-compose.custom.example.yml
./docker-compose.apps.example.yml
./Update-HomelabUpstream.sh
./Update-HomelabUpstream.ps1
./Backup-DataGit.sh
./Backup-DataGit.ps1
./Pull-DataGit.sh
./Pull-DataGit.ps1
./Pull-PkmDataKeepScripts.sh
./Pull-PkmDataKeepScripts.ps1
./Collect-HomelabDiag.sh
./Collect-HomelabDiag.ps1
./Register-DataGitBackup.sh
./Register-DataGitBackupTask.ps1
./Register-DataGitPull.sh
./Register-DataGitPullTask.ps1
./Reindex-PkmFromDisk.sh
./Reindex-PkmFromDisk.ps1
./Caddyfile
./docker-compose.https.yml
./docker/
./cli/
./scriptkit/
./agent-context/
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
  -f docker-compose.custom.yml \
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
3. If Compose reports a container name conflict (`home-hub`, `home-hub-platform`, `pkm-backend`, `pkm-frontend`), leftover containers from a previous project name or a combined stack are still running. Remove them, then `up` again:

   ```bash
   docker rm -f home-hub home-hub-platform pkm-backend pkm-frontend
   ```

4. Always include `docker-compose.config.yml` with the backend `up`. That job creates `data/pkm/bookmarks` and sets its owner to `PUID`/`PGID` even when it skips a recursive `chown` on a world-writable bind mount. If `pkm-backend` still restarts with a permission error on `/app/data/bookmarks`, on a Linux host run `chown -R 1000:1000 data/pkm` (same ids as `.env`) and recreate the backend.
5. From other machines, set `PUBLIC_PKM_URL` to the server IP or hostname, not `127.0.0.1`. Optionally set `PUBLIC_PKM_URL_HTTP` to the plain HTTP LAN URL when `PUBLIC_PKM_URL` is HTTPS. For clipboard paste of images, use the LAN HTTPS overlay below.

Do not bind-mount whole Platform `main.py` / `config.py` into `docker-compose.custom.yml` or `docker-compose.apps.yml`. Prefer a new image (`HOMELAB_VERSION` / `PKM_VERSION`), a site `docker/<service>/Dockerfile` that `FROM`s the published image, or a small `overrides/*/sitecustomize.py` / `default.conf`.

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

Site instances only (`data/` is versioned). `New-HomelabSite` initializes a layered gitignore: `.gitignore.upstream` tracks this package, `.gitignore.custom` holds **only** site extras, and `.gitignore` is generated from both (do not edit it). `Update-HomelabUpstream` refreshes the upstream layer, so custom rules survive product updates. Commits and pushes `data/`, `docker-compose.custom.yml`, `docker-compose.apps.yml`, `overrides/`, `README.md`, the `upstream` pointer, and the site-root launchers that `Update-HomelabUpstream` copies. If someone else pushed to the same branch, the script tries `pull --rebase --autostash`, then falls back to merge. Before Git updates `data/pkm/pkm.db` and `data/hub/platform.db`, Backup/Pull stop `pkm-backend` and `home-hub-platform` so Windows cannot deny writes while Docker holds the files; those containers are started again after the push. After a successful Backup/Pull, Git marks `data/hub/platform.db` and `data/pkm/pkm.db` skip-worktree so `git status` stays clean while Hub/PKM rewrite them at runtime. The next Backup/Pull clears that flag, commits the live databases, then sets it again.

For `data/hub/platform.db` and `data/pkm/pkm.db`, Backup/Pull run a three-way SQLite row merge (`Merge-SqliteGitConflict.py`): rows present on only one side are kept; when the same row changed on both sides, the later `updated_at` (or equivalent timestamp) wins. Rows in `users` and `user_app_grants` are never deleted if they still exist on the other side. FTS, locks, and runtime state are not merged; PKM rebuilds them on reindex. The merged file replaces the canonical db only after integrity and foreign-key checks. If Python or the helper is missing, or schemas differ, the conservative fallback applies: remote stays canonical and the local copy is saved next to it:

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

### Local copy of server data, keep PKM scripts

`Pull-PkmDataKeepScripts.sh` / `.ps1` fetches `origin/<current-branch>` and restores `data/pkm` in the **site root** working tree (deletes extra local PKM files not on origin), then puts back local `data/pkm/scripts`. It does **not** restore `data/hub` (plugin installs stay). No commit or push. Run from the site root or from `upstream/` (same site folder). After `Update-HomelabUpstream`, the launcher is copied to the site root from the product package.

```bash
./Pull-PkmDataKeepScripts.sh
./upstream/Pull-PkmDataKeepScripts.sh
```

```powershell
.\Pull-PkmDataKeepScripts.ps1
.\upstream\Pull-PkmDataKeepScripts.ps1
```

### Troubleshooting dump

`Collect-HomelabDiag.sh` / `.ps1` prints mounts, Hub plugin ids, PKM page order, and whether Guacamole is in site compose. No document bodies and no passwords.

```bash
./Collect-HomelabDiag.sh
```

```powershell
.\Collect-HomelabDiag.ps1
```

### Daily pull (automatic merge)

From the site root. Commits local `data/`, pulls origin, runs the same merge as `Pull-DataGit` (`Merge-SqliteGitConflict.py` for Hub/PKM databases; other conflicts keep remote and archive `*.local-conflict.*`), then pushes and reindexes PKM.

```bash
./Pull.sh
./upstream/Pull.sh
```

```powershell
.\Pull.ps1
.\upstream\Pull.ps1
```

Product images + compose as well:

```bash
./Pull.sh --product --start
```

```powershell
.\Pull.ps1 -Product -Start
```

`Pull.sh` / `Pull.ps1` only wrap `Pull-DataGit` and optional `Update-HomelabUpstream`. After `Update-HomelabUpstream`, the launchers are copied to the site root.

### Two servers — `Pull-DataGit`

If both machines can receive edits, schedule Git on both:

- primary: `Backup-DataGit.sh` or `Backup-DataGit.ps1`
- standby: `Pull-DataGit.sh` or `Pull-DataGit.ps1`

The standby pull first commits local changes in `data/`, `docker-compose.custom.yml`, `docker-compose.apps.yml`, and `README.md`, then syncs with `origin` and pushes. Edits made on either server reach the other on the next run.

If a Market plugin (for example Guacamole) was installed on one host and its files under `data/hub/plugins/<id>/` were pushed, `Pull-DataGit` / `Backup-DataGit` run `Start-MarketPlugins` on the other host: Compose `up` for each plugin folder, join `homelab_default`, restart Platform so the catalog matches. Hub startup does the same if the plugin row or folder is already there.

After the Git sync, `Pull-DataGit` also collapses generic PKM duplicates created when two trees meet: a folder or page named `name-1` next to `name` (Finder/Explorer/Git copy suffix). The canonical name is kept; differing files are archived as `*.local-conflict.*`. Page order (`pages.position`) is snapshotted before the pull and reapplied to the canonical paths after reindex. Names like `ubuntu-22` are left alone (`-1` only).

After a successful Backup or Pull, Linux hosts that run the scripts as root reset `data/pkm` to `PUID`/`PGID` (default `1000:1000`) so the API container can write `bookmarks/` after Git checkout. Then the scripts restart the `pkm-backend` container and call the same APIs as **Import from disk** / **Sync from disk** in the UI (pages, files, PDFs, bookmarks). PKM is down for a few seconds during the restart. Skip with `HOMELAB_PKM_REINDEX_AFTER_SYNC=false` in `.env`, or run `./Reindex-PkmFromDisk.sh` / `.\Reindex-PkmFromDisk.ps1` by itself.

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

## Product CLIs

`cli/lib` holds generic helpers by domain (HTTP, HTML, GitHub, containers, …). `cli/homelab/cve` is the default CVE CLI.

```bash
PYTHONPATH=cli/lib:cli python -m homelab.cve check-jar-version --jar log4j-core --container CONTAINER
PYTHONPATH=cli/lib:cli python -m homelab.cve --config ./cve-sources.json check-fixed-cve --library openssl --version 3.0.16
```

Site instance: site CLIs live under `cli/custom/<name>/`. The product package does not define the tool set. See [`cli/README.md`](./cli/README.md).

## License

OpenDevTools End-User License — internal run/review; no redistribution of images or reuse of the implementation without agreement.
