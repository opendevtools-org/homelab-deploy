# CVE CLI

Default Home Lab CLI under `cli/homelab/cve`. Uses generic domains in `cli/lib` (`net`, `markup`, `versions`, `term`, `env`). Catalog: `config/sources.example.json`.

```bash
PYTHONPATH=cli/lib:cli python -m homelab.cve --help
PYTHONPATH=cli/lib:cli python -m homelab.cve lookup-cve --cve CVE-2024-0001
```
