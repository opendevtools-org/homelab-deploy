# Docker Compose (Hub + PKM)

Work from the **site root** (parent of `upstream/`). Product compose lives in
the submodule. Site extras:

| File | Role | On product update |
|------|------|-------------------|
| `docker-compose.config.yml` | one-shot chown (`data/pkm` + CLI volumes) | refreshed |
| `docker-compose.custom.yml` | Hub/PKM image + `cli/` / `scriptkit/` mounts | kept |
| `docker-compose.apps.yml` | extra apps / Market plugins | kept |

If `upstream/` compose files are missing:

```bash
git submodule update --init --recursive upstream
```

`docker-compose.custom.yml` and `docker-compose.apps.yml` are overlays: they are
not runnable alone. Do not redefine Hub/PKM **images** in `apps.yml`.

## Command

```bash
docker compose --project-directory . \
  -f upstream/docker-compose.backend.yml \
  -f upstream/docker-compose.lan.yml \
  -f docker-compose.config.yml \
  -f docker-compose.custom.yml \
  -f docker-compose.apps.yml \
  up -d
```

`--project-directory .` keeps `.env` and bind mounts (`data/`, `overrides/`,
`cli/`, `scriptkit/`) relative to the site root.

Backend and frontend are **two** Compose projects. Do not combine
`docker-compose.backend.yml` and `docker-compose.frontend.yml` in one `up`.

Before `up`, `.env` must set `PLATFORM_SERVICE_TOKEN`, `HUB_JWT_SECRET`, and
`JWT_SECRET`. Do not write secrets into manifests or agent-context files.

After changing `PUBLIC_PKM_URL`, recreate **hub-platform**. Platform seeds
`plugins.public_url` from that env on startup. Do not patch `platform.db` by
hand and do not bind-mount Platform Python files.

## Named volumes vs bind mounts

A bind mount to a Windows host path is slow for many small files (`git clone`,
Maven cache). Prefer **named Docker volumes** for that I/O; bind-mount only the
source you edit (`./cli`, `./scriptkit`). Named volumes start root-owned:
`docker-compose.config.yml` chowns `site-cli-cache` and `site-cli-home` before
`pkm-backend` starts. `docker-compose.custom.yml` only mounts them.

One-shot permission containers stay `Exited` until `docker compose rm`. That is
normal.
