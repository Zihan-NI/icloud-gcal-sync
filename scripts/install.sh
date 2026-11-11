#!/bin/bash
# Build, install and (re)start the LaunchAgent.   install.sh [--dry-run]
# --dry-run prints the plist and the commands without executing anything.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

xml_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }

render_plist() {
  local env_block=""
  if [ -n "${ICLOUD_GCAL_SYNC_HOME:-}" ]; then
    env_block="  <key>EnvironmentVariables</key>
  <dict>
    <key>ICLOUD_GCAL_SYNC_HOME</key><string>$(xml_escape "$APP_HOME")</string>
  </dict>
"
  fi
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$INSTALLED_BIN")</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
${env_block}  <key>StandardOutPath</key><string>$(xml_escape "$APP_HOME/logs/launchd.out.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$APP_HOME/logs/launchd.err.log")</string>
</dict>
</plist>
PLIST
}

# Setup can be finished from the menu bar icon, so a missing Google sign-in is not an error.
NEEDS_SETUP=""
if [ ! -f "$APP_HOME/credentials.json" ]; then
  NEEDS_SETUP=credentials
elif [ ! -f "$APP_HOME/token.json" ]; then
  NEEDS_SETUP=signin
fi

old_label="com.$(whoami).icloud-gcal-sync"
if [ -f "$HOME/Library/LaunchAgents/$old_label.plist" ] || launchctl print "$DOMAIN/$old_label" >/dev/null 2>&1; then
  echo "note: the old Python LaunchAgent ($old_label) is still installed and would sync in parallel."
  echo "Remove it with:"
  echo "  launchctl bootout $DOMAIN/$old_label && rm ~/Library/LaunchAgents/$old_label.plist"
fi

run "$REPO_ROOT/scripts/build.sh"
run mkdir -p "$APP_HOME/bin" "$APP_HOME/logs" "$HOME/Library/LaunchAgents"
# Stop the running daemon first: overwriting a running signed binary in place
# invalidates its code signature and the kernel kills it. Copy to a temp name and
# rename so the path is replaced atomically.
run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
run cp -f "$REPO_ROOT/dist/icloud-gcal-sync" "$INSTALLED_BIN.new"
run mv -f "$INSTALLED_BIN.new" "$INSTALLED_BIN"
# Copying keeps the signature; verify so a bad copy is caught before launchd uses it.
run codesign --verify --strict "$INSTALLED_BIN"

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] would write $LAUNCH_AGENT_PLIST:"
  render_plist
  render_plist | plutil -lint -
else
  render_plist > "$LAUNCH_AGENT_PLIST"
  plutil -lint "$LAUNCH_AGENT_PLIST"
fi

# bootout returns before teardown finishes; an immediate bootstrap can fail with
# "Input/output error", so retry briefly.
run launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for attempt in 1 2 3 4 5; do
  if run launchctl bootstrap "$DOMAIN" "$LAUNCH_AGENT_PLIST"; then break; fi
  [ "$attempt" = 5 ] && { echo "error: launchctl bootstrap failed" >&2; exit 1; }
  sleep 2
done

cat <<MSG

Installed $LABEL. Logs: $APP_HOME/logs/
Next: macOS will ask once for calendar access, attributed to icloud-gcal-sync.
Click Allow. The grant belongs to this launchd-started process and survives
rebuilds as long as scripts/build.sh keeps using the same signing identity.
MSG

echo "A calendar icon is now in the menu bar: status, Sync Now and Refresh are there."
if [ "$NEEDS_SETUP" = credentials ]; then
  echo "Google is not set up yet: click the icon and pick \"Choose Google Credentials (JSON)…\","
  echo "then sign in when the browser opens."
elif [ "$NEEDS_SETUP" = signin ]; then
  echo "Not signed in to Google yet: click the icon and pick \"Sign In to Google…\"."
fi
