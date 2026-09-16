# CVE CLI

Library code is `homelab_cve/` (JAR inspect, NVD, OpenSSL advisory scrape). The entrypoint is `main.py`. Scan root and library catalogs come from JSON.

```bash
python cli/cve/main.py check-jar-version --jar log4j-core --container CONTAINER
python cli/cve/main.py --config ./cve-sources.json check-fixed-cve --library openssl --version 3.0.16
```

`--jar` is the artifact name with or without `.jar`. Versions come from the manifest, Maven `pom.properties`, or the filename. Use `--json` for automation.

Site-only settings (default scan root, extra libraries): copy `config/sources.example.json` and pass `--config` or `HOMELAB_CVE_CONFIG`. Do not fork the library for a company path.
