#!/bin/bash
# Removes an installation made with the installer package.
#   uninstall.sh           stop the agent, remove the program and the LaunchAgent
#   uninstall.sh --purge   also remove the configuration, Google sign-in and database
set -euo pipefail

LABEL="com.github.icloud-gcal-sync"
APP_HOME="$HOME/Library/Application Support/icloud-gcal-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
purge=0
case "${1:-}" in
  "") ;;
  --purge) purge=1 ;;
  *) echo "usage: $0 [--purge]" >&2; exit 2 ;;
esac

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
pkgutil --volume "$HOME" --forget "$LABEL.pkg" >/dev/null 2>&1 || true
if [ "$purge" = 1 ]; then
  rm -rf "$APP_HOME"
  echo "Removed icloud-gcal-sync and its data."
else
  # This script lives in bin/: remove the program but keep the data next to it.
  rm -f "$APP_HOME/bin/icloud-gcal-sync" "$APP_HOME/bin/uninstall.sh"
  rmdir "$APP_HOME/bin" 2>/dev/null || true
  echo "Removed icloud-gcal-sync. Configuration, Google sign-in and database are kept in:"
  echo "  $APP_HOME"
  echo "Run with --purge next time to remove them too."
fi
echo "macOS keeps the calendar permission entry: remove icloud-gcal-sync under"
echo "System Settings > Privacy & Security > Calendars."
