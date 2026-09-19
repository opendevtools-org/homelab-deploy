# Site CLI library (`odt_scripts`)

Python helpers for PKM launchers and site CLIs. This folder is **product code**:
`Update-HomelabUpstream` refreshes it. Put your own commands in `cli/custom/<name>/`, not here.

Layout:

```
cli/custom/<name>/src/main.py   # your CLI (site-owned, never overwritten)
data/pkm/scripts/<name>/        # PKM launcher + manifest.json (site data)
scriptkit/odt_scripts/          # this library (refreshed from upstream)
```

Inside the PKM container, set `PYTHONPATH=/app/scriptkit:/overrides` (see
`docker-compose.custom.example.yml`).

Typical launcher:

```python
from odt_scripts.launcher import run_cli_from_stdin
raise SystemExit(run_cli_from_stdin(["python", "/app/cli/custom/mytool/src/main.py", "run"]))
```

The launcher reads the PKM form JSON from stdin, writes a temp file, calls the CLI
with `--input-json`, forwards stdout/stderr/exit, and deletes the temp file.

See `examples/echo_cli/` and `agent-context/pkm/SCRIPTS.md`.
