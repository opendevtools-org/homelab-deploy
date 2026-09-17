# Product CLIs

| Path | Role |
|------|------|
| `cli/lib/` | Generic helpers by domain (`term`, `containers`, `github`, `compose`, `mdblocks`, `env`, `net`, `markup`, `versions`). Not tied to CVE or any CLI. |
| `cli/homelab/` | Default Home Lab CLIs (`cve`, …) |
| `cli/custom/` | Site overlay: wrappers + tests |

```bash
cd cli
python -m unittest discover -s custom/tests -p "test_*.py"
PYTHONPATH=lib:. python -m homelab.cve check-fixed-cve --library openssl --version 3.0.16
python custom/cve/main.py lookup-cve --cve CVE-2024-0001
```

Copy `homelab/cve/config/sources.example.json` to the site. Optional `NVD_API_KEY` or `HOMELAB_CVE_DOTENV`.
