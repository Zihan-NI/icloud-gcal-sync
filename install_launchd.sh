#!/bin/bash
# Install (or reinstall) a LaunchAgent that runs sync.py every 5 minutes.
# Uninstall:  launchctl bootout gui/$(id -u)/com.$(whoami).icloud-gcal-sync && rm ~/Library/LaunchAgents/com.$(whoami).icloud-gcal-sync.plist
set -euo pipefail

LABEL="com.$(whoami).icloud-gcal-sync"
DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL="${1:-300}"

mkdir -p "$DIR/logs" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DIR/.venv/bin/python</string>
    <string>$DIR/sync.py</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$DIR/logs/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/launchd.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL (every ${INTERVAL}s). Logs: $DIR/logs/sync.log"
