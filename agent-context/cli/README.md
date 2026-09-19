# Deploy CLIs

Product tree under `cli/` (not PKM `odt_scripts` launchers). Three layers:

| Path | Role |
|------|------|
| `cli/lib/` | Generic helpers by **domain**. Put `cli/lib` on `PYTHONPATH`. |
| `cli/homelab/` | Default product CLIs (`python -m homelab.cve`). Catalog example: `cli/homelab/cve/config/sources.example.json`. |
| `cli/custom/` | Site overlay. Which tools live here is site-owned; keep company hostnames and tokens out of the product repo. |

Do not import product CVE parsers from `lib`. Do not put registries or GHES URLs in `lib/` or `homelab/`. Do not place site tools at `cli/<name>/` next to `lib/` / `homelab/` / `custom/`.

```bash
cd cli
PYTHONPATH=lib:. python -m homelab.cve --help
python -m unittest discover -s custom/tests -p "test_*.py"
```

Product CVE entry: `homelab.cve.cli`. Optional `NVD_API_KEY` or `HOMELAB_CVE_DOTENV`.
