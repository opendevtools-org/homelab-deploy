# Site overlay (`custom/`)

Wrappers and tests. Product helpers: `cli/lib/`. Default CLIs: `cli/homelab/`.

```bash
python -m unittest discover -s cli/custom/tests -p "test_*.py"
PYTHONPATH=cli/lib:cli python -m homelab.cve --help
python cli/custom/cve/main.py --help
```
