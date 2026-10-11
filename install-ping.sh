#!/bin/zsh
# Installs a launchd agent that runs ping-haiku.sh at login and every 5 hours.
# Pass --uninstall to remove it.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="local.mueed.claude-ping"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$HOME/Library/Application Support/ClaudeSwitcher/ping-haiku.sh"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$PLIST" "$SCRIPT"
  echo "Removed $LABEL"
  exit 0
fi

mkdir -p "${SCRIPT:h}" "${PLIST:h}"
install -m 755 ping-haiku.sh "$SCRIPT"

# 5 hours and 1 minute, so each ping lands after the previous window has ended.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/zsh</string><string>$SCRIPT</string></array>
    <key>StartInterval</key><integer>18060</integer>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL; log: ~/Library/Logs/ClaudeSwitcher-ping.log"
