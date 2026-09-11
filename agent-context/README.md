# Agent context

Short notes for agents working on a Hub + PKM **site instance**. Product files
in this folder are refreshed by `Update-HomelabUpstream`. Site-only notes go in
[`site/`](site/README.md) and are never overwritten.

## Hub / PKM (product)

- [Docker Compose](hub/DOCKER-COMPOSE.md): overlays, named volumes, `.env`.
- [PKM scripts and CLIs](pkm/SCRIPTS.md): `cli/`, launchers, `odt_scripts`.
- [Validation](pkm/VALIDATION.md): compile, unittest, `compose config`.

Read only the files that match the change. Do not load the whole site tree.
