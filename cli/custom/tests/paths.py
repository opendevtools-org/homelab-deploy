import sys
from pathlib import Path

CLI_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CLI_ROOT / "lib"))
sys.path.insert(0, str(CLI_ROOT))

CVE_ROOT = CLI_ROOT / "homelab" / "cve"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
