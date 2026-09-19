# Site notes

Put instance-only agent notes here (extra compose services, local CLIs, host
paths). `Update-HomelabUpstream` skips this folder.

Site CLIs belong only in `cli/custom/<name>/` and import `cli/lib` plus
`cli/homelab` (see product [cli/README.md](../cli/README.md)). Copy catalogs
and tokens into `cli/custom/<name>/config/`, not into `cli/lib` or `cli/homelab`.
