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
| `homelab-frontend` | `docker-compose.frontend.yml` | device or same host | Hub UI + PKM UI |
| | `docker-compose.frontend.lan.yml` or `.frontend.local.yml` | device or same host | UI host ports |

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

## Flat install — web clients (devices)

On each device, set the server URLs in `.env`. On the **same host** as the APIs, the defaults (`host.docker.internal`) are enough:

```bash
# Device only — point at the server:
# HUB_API_UPSTREAM=http://SERVER:8090
# PKM_API_UPSTREAM=http://SERVER:8001
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml up -d
```

| | |
|--|--|
| Hub UI | http://DEVICE:3080 |
| PKM UI | http://DEVICE:3030 |

Login: `HUB_ADMIN_*` from `.env`. Create users under Utenti. Data in `./data/hub` and `./data/pkm` (gitignored) on the **server**.

## Community plugins (Hub Market)

Public plugins live in [`opendevtools-org/hub-community-plugins`](https://github.com/opendevtools-org/hub-community-plugins).

- **Backend:** `plugins/<id>/docker-compose.backend.yml` — Market copies this into `docker-compose.apps.yml` on the server.
- **Web client:** `plugins/<id>/docker-compose.frontend.yml` — run on a device with `*_API_UPSTREAM` pointing at the server.

From Hub `/market`, **Installa** starts the plugin backend on the Platform server and opens the web client in that Hub (`/p/{id}/`). Merge the plugin’s `.env.example` into `.env` if it has one.

Upgrade (flat, server):

```bash
git pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml pull
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml -f docker-compose.config.yml -f docker-compose.apps.yml up -d
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml pull
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml up -d
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
```

`--project-directory .` so volumes hit this folder’s `data/`.

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
| `--push` / `-Push` | off | Push (implies commit). |
| `--start` / `-Start` | off | Compose pull + up (includes apps). |
| `--ports` / `-Ports` | `lan` | Ports overlay with start. |

### Daily data backup — `Backup-DataGit`

Site instances only (`data/` is versioned; flat install gitignores it). Commits and pushes `data/`, `docker-compose.apps.yml`, and `README.md`. If someone else pushed to the same branch, the script tries `pull --rebase --autostash`, then falls back to merge. On a real conflict it keeps the remote file as canonical and saves the local copy next to it:

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
