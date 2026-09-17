# Deploy CLIs

Product tree under `cli/` (not PKM `odt_scripts` launchers). Three layers:

| Path | Role |
|------|------|
| `cli/lib/` | Generic helpers by **domain**. Not a CVE library and not a CLI. Domains: `term`, `containers`, `github`, `compose`, `mdblocks`, `env`, `net`, `markup`, `versions`. Put `cli/lib` on `PYTHONPATH`. |
| `cli/homelab/` | Default Home Lab CLIs. Today: `cve` (`python -m homelab.cve` with `PYTHONPATH=cli/lib:cli`). Catalog example: `cli/homelab/cve/config/sources.example.json`. |
| `cli/custom/` | Site overlay: wrappers, extra CLIs, tests. Product update must not require company hostnames here in the **product** repo — keep those in the site `custom/` and in `agent-context/site/`. |

Do not import CVE parsers from `lib`. Do not put company registries or GHES URLs in `lib/` or `homelab/`.

```bash
cd cli
python -m unittest discover -s custom/tests -p "test_*.py"
PYTHONPATH=lib:. python -m homelab.cve --help
```

CVE entry: `homelab.cve.cli`. Commands: `check-jar-version`, `check-fixed-cve`, `lookup-cve`, `compare-inventory`. Optional `NVD_API_KEY` or `HOMELAB_CVE_DOTENV`. Go / Kubernetes / Python are lookup-only (`check-fixed-cve` exits 2).

Site wrapper typically: `python custom/cve/main.py` (injects local `--config`).
