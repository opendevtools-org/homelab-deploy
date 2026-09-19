# Site overlay (`custom/`)

All site-owned CLIs live under this folder. Product code stays in `cli/lib/` and `cli/homelab/`.

Layout for each tool (names are chosen by the site):

```
cli/custom/<name>/main.py      # optional wrapper (entry used by PKM / --help)
cli/custom/<name>/src/main.py  # optional implementation
cli/custom/<name>/config/      # catalogs, tokens, site config (not in lib/ or homelab/)
```

Do not add site tools as siblings of `custom/` (`cli/<name>/` next to `lib/` / `homelab/`).

```bash
python cli/custom/<name>/main.py --help
PYTHONPATH=cli/lib:cli python -m homelab.cve --help
python -m unittest discover -s cli/custom -p "test_*.py"
```
