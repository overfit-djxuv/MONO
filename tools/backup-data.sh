#!/bin/zsh
# Copies MONO's data off the iPhone to ~/MONO-backups/<timestamp>/ whenever the phone is reachable.
# - Read-only on the phone: it only pulls files, never writes or deletes anything there.
# - At most one backup per MIN_AGE_HOURS (default 20); FORCE=1 backs up immediately.
# - Each copy is checked with SQLite's integrity check on a scratch copy; a damaged copy is discarded and retried.
# - Keeps the newest KEEP backups (default 14) and deletes older ones.
# Restore (only ever over the installed app, never after deleting it): copy the files back with
#   xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier com.example.monoapp ...

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

SCRIPT_DIR="${0:A:h}"
[[ -f "$SCRIPT_DIR/local.env" ]] && source "$SCRIPT_DIR/local.env"
if [[ -z "$DEVICE" ]]; then echo "Set DEVICE (your iPhone UDID) in tools/local.env; see tools/local.env.example" >&2; exit 1; fi
BUNDLE="com.example.monoapp"
ROOT="$HOME/MONO-backups"
STATE="$HOME/Library/Application Support/MONO-refresh"
LOG="$STATE/backup.log"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-20}"
KEEP="${KEEP:-14}"

mkdir -p "$ROOT" "$STATE"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

LOCK="$STATE/backup.lock"
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK"' EXIT

stamp="$STATE/last-backup"
age_hours=9999
[[ -f "$stamp" ]] && age_hours=$(( ( $(date +%s) - $(stat -f %m "$stamp") ) / 3600 ))
if [[ -z "${FORCE:-}" && $age_hours -lt $MIN_AGE_HOURS ]]; then exit 0; fi

if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE \(UDID\) +(connected|available)"; then
  log "iPhone not reachable (last backup ${age_hours}h ago); will retry"
  exit 0
fi

for attempt in 1 2 3; do
  dest="$ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dest/Library/Application Support"
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
       --source "Library/Application Support/MONO" --destination "$dest/Library/Application Support/" >> "$LOG" 2>&1 \
     && xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
       --source "Library/Preferences/$BUNDLE.plist" --destination "$dest/$BUNDLE.plist" >> "$LOG" 2>&1; then
    scratch=$(mktemp -d)
    cp "$dest/Library/Application Support/"MONO.store* "$scratch"/ 2>/dev/null
    if [[ "$(sqlite3 "$scratch/MONO.store" 'pragma integrity_check;' 2>&1)" == "ok" ]]; then
      n=$(sqlite3 "$scratch/MONO.store" 'select count(*) from ZTRANSACTIONRECORD;' 2>/dev/null)
      rm -rf "$scratch"
      touch "$stamp"
      log "backup OK -> ${dest:t} (${n:-?} transactions)"
      # prune: keep the newest $KEEP
      ls -1d "$ROOT"/[0-9]*/ 2>/dev/null | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do rm -rf "$old"; log "pruned ${old:t}"; done
      exit 0
    fi
    rm -rf "$scratch"
    log "attempt $attempt: copy failed the integrity check (phone was probably writing); retrying"
  else
    log "attempt $attempt: copy failed (phone locked or busy?)"
  fi
  rm -rf "$dest"
  sleep 5
done
log "BACKUP FAILED after 3 attempts"
exit 1
