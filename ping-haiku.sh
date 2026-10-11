#!/bin/zsh
# Sends one tiny Haiku message per CLI login so each account's 5-hour window starts right away.
# Run every 5 hours by launchd (see install-ping.sh). Logs to ~/Library/Logs/ClaudeSwitcher-ping.log.
set -u

# launchd runs this with a bare PATH, so look in the usual install locations.
for CLAUDE in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [[ -x "$CLAUDE" ]] && break
done
LOG="$HOME/Library/Logs/ClaudeSwitcher-ping.log"
WORKDIR="$HOME/Library/Application Support/ClaudeSwitcher"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# "" is the default login in ~/.claude.json; every ~/.claude-*/ folder with a login is another account.
dirs=("")
for dir in "$HOME"/.claude-*(N/); do
  [[ -f "$dir/.claude.json" ]] && dirs+=("${dir%/}")
done

for dir in "${dirs[@]}"; do
  label="${dir:-default}"
  if [[ -n "$dir" ]]; then
    reply=$(CLAUDE_CONFIG_DIR="$dir" "$CLAUDE" -p "hi" --model haiku --no-session-persistence --strict-mcp-config 2>&1)
  else
    reply=$("$CLAUDE" -p "hi" --model haiku --no-session-persistence --strict-mcp-config 2>&1)
  fi
  code=$?
  print -r -- "$(date '+%F %T')  ${label:t}  exit=$code  ${${reply//$'\n'/ }[1,120]}" >> "$LOG"
done
