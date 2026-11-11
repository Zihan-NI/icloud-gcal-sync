# Shared definitions, sourced by the other scripts. Not executable on its own.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_HOME="${ICLOUD_GCAL_SYNC_HOME:-$HOME/Library/Application Support/icloud-gcal-sync}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$REPO_ROOT/Support/Info.plist")"
# launchd and the daemon resolve this path from other working directories.
case "$APP_HOME" in
  /*) ;;
  *) echo "error: ICLOUD_GCAL_SYNC_HOME must be an absolute path (got '$APP_HOME')" >&2; exit 1 ;;
esac
SIGNING_NAME="icloud-gcal-sync local signing"
SIGNING_KEYCHAIN="$APP_HOME/signing.keychain-db"
SIGNING_PASS_FILE="$APP_HOME/signing.keychain.pass"
LABEL="$BUNDLE_ID"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALLED_BIN="$APP_HOME/bin/icloud-gcal-sync"
DOMAIN="gui/$(id -u)"

# Echo the command in dry-run mode, run it otherwise. DRY_RUN is set by the caller.
run() {
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}
