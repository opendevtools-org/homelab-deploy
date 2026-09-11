# Site Dockerfiles

Put extra packages (Java, Maven, compilers, …) in a **site** Dockerfile that
`FROM` the published image. `Update-HomelabUpstream` refreshes `*.example` and
this README. It never overwrites `Dockerfile` or `docker-compose.custom.yml`.

| File | Owner | On product update |
|------|--------|-------------------|
| `docker/pkm-backend/Dockerfile.example` | product | refreshed |
| `docker/pkm-backend/Dockerfile` | site | kept |
| `docker-compose.custom.yml` | site | kept |
| `docker-compose.config.yml` | product | refreshed (includes volume chown) |
| `docker-compose.apps.yml` | site | kept (plugins only) |

Steps:

1. `cp docker/pkm-backend/Dockerfile.example docker/pkm-backend/Dockerfile`
2. Uncomment or add `apt-get install` lines.
3. Copy the `pkm-backend` snippet from `docker-compose.custom.example.yml`
   into `docker-compose.custom.yml`.
4. Recreate: `docker compose … -f docker-compose.custom.yml -f docker-compose.apps.yml up -d --build`

Do not bind-mount whole Hub/PKM `main.py` / `config.py`. Prefer this image
extension, or a small `overrides/*/sitecustomize.py`.
