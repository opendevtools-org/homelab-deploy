# Product CLIs

| Path | Role |
|------|------|
| `cli/lib/` | Shared helpers by domain (`term`, `containers`, `github`, `compose`, `mdblocks`, `env`, `net`, `markup`, `versions`). |
| `cli/homelab/` | Default product CLIs (`python -m homelab.cve`). |
| `cli/custom/` | Site-owned tools. The product package does not define which CLIs a site adds here. |

```bash
cd cli
PYTHONPATH=lib:. python -m homelab.cve --help
python -m unittest discover -s custom/tests -p "test_*.py"
```

Site tools: see `cli/custom/README.md`. Optional CVE catalog copy: `homelab/cve/config/sources.example.json` → `custom/<tool>/config/` on the site. Optional `NVD_API_KEY` or `HOMELAB_CVE_DOTENV`.
