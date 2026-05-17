#!/usr/bin/env zsh
set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.openlidsounds.agent.plist"

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"

echo "Uninstalled Open Lid Sound launch agent."
