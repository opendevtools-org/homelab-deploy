# Validation

After Python or manifest edits:

```bash
python -m py_compile path/to/file.py
python -m unittest discover -s scriptkit/tests
python -m unittest discover -s cli/custom/tests -p "test_*.py"
python -c "import json; json.load(open('data/pkm/scripts/NAME/manifest.json', encoding='utf-8')); print('manifest ok')"
```

From `cli/` the deploy CLI smoke (help + unit tests, no Docker) is `./smoke.ps1` when the site copied it; product tests live in `cli/custom/tests`.

PKM launcher checks:

- valid JSON on stdin
- empty stdin → `{}`
- stdout, stderr, and exit code forwarded
- temp `--input-json` file deleted

Compose overlay:

```bash
docker compose --project-directory . \
  -f upstream/docker-compose.backend.yml \
  -f upstream/docker-compose.lan.yml \
  -f docker-compose.custom.yml \
  -f docker-compose.apps.yml \
  -f docker-compose.config.yml \
  config --quiet
```

Separate CLI errors, launcher errors, host env, and container env before
changing product compose.
