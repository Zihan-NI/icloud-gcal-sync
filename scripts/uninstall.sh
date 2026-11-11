#!/bin/bash
# Stop and remove the LaunchAgent and installed binary.   uninstall.sh [--purge] [--dry-run]
# --purge also deletes APP_HOME (config, token, database, logs, signing keychain).
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: $0 [--purge] [--dry-run]" >&2; exit 2 ;;
  esac
done

if [ "$PURGE" = 1 ]; then
  # rm -rf on a user-supplied path: refuse anything that is obviously not a private app dir.
  case "$APP_HOME" in
    /|"$HOME"|"$HOME/"|"$HOME/Library"|"$HOME/Library/Application Support")
      echo "error: refusing to --purge '$APP_HOME'" >&2; exit 1 ;;
  esac
fi

run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
run rm -f "$LAUNCH_AGENT_PLIST" "$INSTALLED_BIN"

if [ "$PURGE" = 1 ]; then
  # The keychain was never added to the user search list, so deleting it is enough.
  if [ -f "$SIGNING_KEYCHAIN" ]; then
    run security delete-keychain "$SIGNING_KEYCHAIN" || echo "warning: could not delete the signing keychain" >&2
  fi
  run rm -rf "$APP_HOME"
else
  echo "Kept $APP_HOME (config, token, database, signing keychain). Use --purge to remove it."
fi

[ "$DRY_RUN" = 1 ] && echo "[dry-run] nothing was changed. A real run would report:"
cat <<MSG
Removed the LaunchAgent and the installed binary.
The calendar permission entry must be removed by hand: System Settings >
Privacy & Security > Calendars. (tccutil reset Calendar $BUNDLE_ID does not
work for a bare command-line tool: "No such bundle identifier".)
MSG
