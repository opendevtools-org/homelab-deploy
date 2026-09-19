# Site code overrides

Drop a file here and recreate the container. No image rebuild.

| Folder | Mounted as | What to put |
|--------|------------|-------------|
| `hub-platform/` | `/overrides` + `PYTHONPATH` | `sitecustomize.py` (Python imports it at startup) |
| `pkm-backend/` | `/overrides` + `PYTHONPATH` | `sitecustomize.py` |
| `hub-frontend/` | `/overrides` | `default.conf` (replaces the nginx template if present) |
| `pkm-frontend/` | `/overrides` | `default.conf` (same) |

Python: `sitecustomize.py` is loaded from `/overrides` regardless of the image’s Python minor version. Patch functions; do not copy whole `main.py` / `config.py` unless you also bind-mount them in `docker-compose.custom.yml`.

Nginx: if `default.conf` exists, the container copies it onto the stock template at start.

Empty folders are required so Compose bind-mounts succeed. Recreate after adding a file:

```bash
docker compose -f docker-compose.backend.yml -f docker-compose.lan.yml \
  -f docker-compose.custom.yml -f docker-compose.apps.yml \
  -f docker-compose.config.yml up -d
docker compose -f docker-compose.frontend.yml -f docker-compose.frontend.lan.yml up -d
```
