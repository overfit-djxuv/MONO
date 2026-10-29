#!/bin/zsh
# Re-signs and re-installs MONO on the iPhone over the existing app so the free 7-day profile never lapses.
# - Installs IN PLACE (never uninstalls), so the app's data is kept.
# - Does nothing unless the last successful refresh is MAX_AGE_DAYS or older (default 4).
# - Needs the Mac awake and the iPhone reachable (cable, or "Connect via network" on the same Wi-Fi).
# Run by launchd every few hours; run by hand with FORCE=1 to refresh immediately.

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

PROJECT="$HOME/MONO/MONO.xcodeproj"
SCRIPT_DIR="${0:A:h}"
[[ -f "$SCRIPT_DIR/local.env" ]] && source "$SCRIPT_DIR/local.env"
if [[ -z "$DEVICE" || -z "$BUNDLE_ID_PREFIX" ]]; then echo "Set DEVICE and BUNDLE_ID_PREFIX in tools/local.env; see tools/local.env.example" >&2; exit 1; fi
BUNDLE="$BUNDLE_ID_PREFIX.monoapp"
STATE="$HOME/Library/Application Support/MONO-refresh"
DERIVED="$HOME/Library/Caches/MONO-refresh-build"
LOG="$STATE/refresh.log"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-4}"   # refresh well inside the 7-day window so a few missed days are harmless
WARN_AT_DAYS=5
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE_BACKUP="$STATE/profile-backup"

mkdir -p "$STATE"
log()    { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"MONO\"" >/dev/null 2>&1; }

# one run at a time
LOCK="$STATE/lock"
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK"' EXIT

stamp="$STATE/last-success"
age_days=999
[[ -f "$stamp" ]] && age_days=$(( ( $(date +%s) - $(stat -f %m "$stamp") ) / 86400 ))

if [[ -z "${FORCE:-}" && $age_days -lt $MAX_AGE_DAYS ]]; then exit 0; fi

# Is the phone reachable right now?
if ! xcrun devicectl list devices 2>/dev/null | grep -Eq "$DEVICE \(UDID\) +(connected|available)"; then
  log "iPhone not reachable (last refresh ${age_days}d ago); will retry"
  if [[ $age_days -ge $WARN_AT_DAYS && $age_days -ne 999 && ! -f "$STATE/warned-$(date +%F)" ]]; then
    touch "$STATE/warned-$(date +%F)"
    notify "Can't reach your iPhone. Connect it (or turn on Connect via network) so MONO can be renewed before it stops opening."
  fi
  exit 0
fi

log "refreshing (last success ${age_days}d ago)"

# Xcode reuses its cached profile (and its original expiry) if one exists. Setting it aside makes
# Xcode ask Apple for a fresh one, which restarts the 7-day clock. Restored below if anything fails.
rm -rf "$PROFILE_BACKUP"; mkdir -p "$PROFILE_BACKUP"
for f in "$PROFILES"/*.mobileprovision(N); do mv "$f" "$PROFILE_BACKUP"/; done
restore_profiles() { for f in "$PROFILE_BACKUP"/*.mobileprovision(N); do [[ -e "$PROFILES/${f:t}" ]] || mv "$f" "$PROFILES"/; done; }

if ! xcodebuild -project "$PROJECT" -scheme MONO -configuration Release \
      -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build >> "$LOG" 2>&1; then
  restore_profiles; log "BUILD FAILED (previous profile restored)"; notify "MONO renewal failed to build. See refresh.log."; exit 1
fi

APP="$DERIVED/Build/Products/Release-iphoneos/MONO.app"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  log "INSTALL FAILED"; notify "MONO renewal couldn't install. See refresh.log."; exit 1
fi

exp=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
hours_left=""
if [[ -n "$exp" ]]; then
  exp_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$exp" +%s 2>/dev/null)
  [[ -n "$exp_epoch" ]] && hours_left=$(( (exp_epoch - $(date +%s)) / 3600 ))
fi
touch "$stamp"
log "installed OK; profile expires $exp (${hours_left:-?} hours left)"

# A fresh profile has ~167h. If it is much lower, the old profile was reused and nothing was extended.
if [[ -z "$hours_left" || $hours_left -lt 160 ]]; then
  log "WARNING: profile was not extended"
  rm -f "$stamp"   # make the next run try again instead of waiting days
  notify "MONO was re-installed but its signing was NOT extended. Open Xcode and press Run once, or tell Claude."
else
  notify "MONO renewed. Valid until $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$exp" '+%d %b %Y' 2>/dev/null)."
fi
