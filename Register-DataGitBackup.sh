#!/usr/bin/env bash
# Registers a daily cron job to run Backup-DataGit.sh.
# Same role as Register-DataGitBackupTask.ps1 (Windows Scheduled Task).
#
# Usage (from site root):
#   ./Register-DataGitBackup.sh
#   ./Register-DataGitBackup.sh --time 03:30
#   ./Register-DataGitBackup.sh --time 00:05 --uninstall
set -euo pipefail

TIME="00:05"
UNINSTALL=0
MARKER="# homelab-data-git-backup"

usage() {
  echo "Usage: $0 [--time HH:MM] [--uninstall]"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --time) TIME="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ ! "$TIME" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "--time must be HH:MM (24h), got: $TIME" >&2
  exit 1
fi

HOUR="${TIME%%:*}"
MINUTE="${TIME##*:}"
# strip leading zeros for cron
HOUR=$((10#$HOUR))
MINUTE=$((10#$MINUTE))

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_ROOT/Backup-DataGit.sh"

[[ -f "$BACKUP_SCRIPT" ]] || { echo "Missing script: $BACKUP_SCRIPT" >&2; exit 1; }
chmod +x "$BACKUP_SCRIPT" "$SCRIPT_ROOT/Register-DataGitBackup.sh" 2>/dev/null || true

if [[ ! -d "$SCRIPT_ROOT/data" ]]; then
  echo "Warning: no data/ folder found. Register anyway; run from a site instance root for backups to work." >&2
fi

command -v crontab >/dev/null 2>&1 || { echo "crontab is required" >&2; exit 1; }

CRON_LINE="${MINUTE} ${HOUR} * * * cd \"${SCRIPT_ROOT}\" && /bin/bash \"${BACKUP_SCRIPT}\" >>\"${SCRIPT_ROOT}/logs/backup-data-git.cron.log\" 2>&1 ${MARKER}"

EXISTING="$(crontab -l 2>/dev/null || true)"
FILTERED="$(printf '%s\n' "$EXISTING" | grep -vF "$MARKER" || true)"

if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -z "$FILTERED" ]]; then
    crontab -r 2>/dev/null || true
  else
    printf '%s\n' "$FILTERED" | crontab -
  fi
  echo "Removed Homelab data git backup cron entry (if present)."
  exit 0
fi

{
  [[ -n "$FILTERED" ]] && printf '%s\n' "$FILTERED"
  printf '%s\n' "$CRON_LINE"
} | crontab -

mkdir -p "$SCRIPT_ROOT/logs"
echo "Cron job registered for every day at ${TIME} (${MINUTE} ${HOUR} * * *)."
echo "Log: ${SCRIPT_ROOT}/logs/backup-data-git.cron.log"
echo "Uninstall: $0 --uninstall"
