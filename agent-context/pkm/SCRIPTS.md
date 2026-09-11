# PKM scripts and site CLIs

Two layers:

| Path | Role | On product update |
|------|------|-------------------|
| `cli/<name>/src/` | Real CLI (`argparse` commands) | kept (site) |
| `data/pkm/scripts/<name>/` | PKM launcher + `manifest.json` | kept (site data) |
| `scriptkit/odt_scripts/` | Shared library | refreshed |

The PKM UI posts the form as JSON on **stdin**. The launcher must:

1. Read and validate all of stdin (empty → `{}`).
2. Write a temp JSON file.
3. Invoke the CLI with `--input-json`.
4. Forward stdout, stderr, and the exit code.
5. Delete the temp file in `finally`.

Use the product helper:

```python
from odt_scripts.launcher import run_cli_from_stdin
raise SystemExit(run_cli_from_stdin(["python", "/app/cli/mytool/src/main.py", "run"]))
```

`manifest.json` `parameters` need `name`, `type`, `label`, `required`. Parameter
names must match the JSON keys the CLI expects. Do not put tokens in the
manifest; read them from the container environment (`odt_scripts.env.first_env`).

`manifest.json` `download` paths must be relative to the script directory.
PKM exposes artifacts only when the process exits 0.

Mounts (from `docker-compose.custom.example.yml`):

- `./cli:/app/cli:ro` — your commands
- `./scriptkit:/app/scriptkit:ro` — library
- `PYTHONPATH=/app/scriptkit:/overrides`

Copy `scriptkit/examples/echo_cli/` into `cli/<name>/` and
`data/pkm/scripts/<name>/` when adding a tool. Extra OS packages (Java, Maven)
go in `docker/pkm-backend/Dockerfile`, not in the library.
