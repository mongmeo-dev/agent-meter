#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${SWIFT_BIN:-}" ]]; then
    read -r -a SWIFT_COMMAND <<< "$SWIFT_BIN"
elif command -v xcrun >/dev/null; then
    SWIFT_COMMAND=(xcrun swift)
else
    SWIFT_COMMAND=(swift)
fi

"${SWIFT_COMMAND[@]}" build -c release --product AgentMeter
BIN_DIR="$("${SWIFT_COMMAND[@]}" build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/AgentMeter"
if [[ ! -x "$EXECUTABLE" ]]; then
    printf 'AgentMeter executable not found at %s\n' "$EXECUTABLE" >&2
    exit 1
fi

APP_DIR="$ROOT_DIR/.build/Agent Meter.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/AgentMeter"
chmod 755 "$APP_DIR/Contents/MacOS/AgentMeter"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Agent Meter</string>
    <key>CFBundleExecutable</key>
    <string>AgentMeter</string>
    <key>CFBundleIdentifier</key>
    <string>dev.mongmeo.agent-meter</string>
    <key>CFBundleName</key>
    <string>Agent Meter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --timestamp=none "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
