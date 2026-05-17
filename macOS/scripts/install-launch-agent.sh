#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_ROOT/.build/release/OpenLidSounds"
APP_BUNDLE="$PROJECT_ROOT/OpenLidSounds.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openlidsounds.agent.plist"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Binary not found or not executable: $BINARY_PATH"
  echo "Build first with: swift build -c release"
  exit 1
fi

# ── Assemble .app bundle ───────────────────────────────────────────────────────
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY_PATH"                          "$MACOS/OpenLidSounds"
cp "$PROJECT_ROOT/Sources/Info.plist"      "$CONTENTS/Info.plist"
cp "$PROJECT_ROOT/icon/OpenLidSounds.icns" "$RESOURCES/OpenLidSounds.icns"

# Keep a symlink so the bundle can still find the sound_effects folder
# relative to the project root (AppPaths resolves 3 levels up from executable).
echo "App bundle assembled at $APP_BUNDLE"

# ── LaunchAgent plist ─────────────────────────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.openlidsounds.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MACOS/OpenLidSounds</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/OpenLidSounds.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/OpenLidSounds.err</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/com.openlidsounds.agent"
launchctl kickstart -k "gui/$(id -u)/com.openlidsounds.agent"

echo "Installed and started Open Lid Sound launch agent."
