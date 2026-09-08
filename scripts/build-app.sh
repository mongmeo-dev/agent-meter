#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="${APP_VERSION:-${VERSION:-1.0.0}}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-${BUILD_NUMBER:-$APP_VERSION}}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
REQUIRE_SPARKLE_SIGNATURE="${REQUIRE_SPARKLE_SIGNATURE:-0}"
SIGNING_MODE="${SIGNING_MODE:-adhoc}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SPARKLE_FEED_URL="https://github.com/mongmeo-dev/agent-meter/releases/latest/download/appcast.xml"

if [[ ! "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'APP_VERSION must be a stable semantic version (for example, 1.2.3): %s\n' \
        "$APP_VERSION" >&2
    exit 1
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf 'APP_BUILD_NUMBER must contain one to three period-separated integers: %s\n' \
        "$APP_BUILD_NUMBER" >&2
    exit 1
fi
if [[ "$REQUIRE_SPARKLE_SIGNATURE" != "0" && "$REQUIRE_SPARKLE_SIGNATURE" != "1" ]]; then
    printf 'REQUIRE_SPARKLE_SIGNATURE must be 0 or 1\n' >&2
    exit 1
fi
if [[ -n "$SPARKLE_PUBLIC_KEY" && ! "$SPARKLE_PUBLIC_KEY" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    printf 'SPARKLE_PUBLIC_KEY must be a base64-encoded EdDSA public key\n' >&2
    exit 1
fi
if [[ "$REQUIRE_SPARKLE_SIGNATURE" == "1" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
    printf 'SPARKLE_PUBLIC_KEY is required for a signed release build\n' >&2
    exit 1
fi
case "$SIGNING_MODE" in
    adhoc)
        ;;
    developer-id)
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            printf 'SIGNING_IDENTITY is required for Developer ID signing\n' >&2
            exit 1
        fi
        ;;
    *)
        printf 'SIGNING_MODE must be adhoc or developer-id\n' >&2
        exit 1
        ;;
esac

if [[ -n "${SWIFT_BIN:-}" ]]; then
    read -r -a SWIFT_COMMAND <<< "$SWIFT_BIN"
elif command -v xcrun >/dev/null; then
    SWIFT_COMMAND=(xcrun swift)
else
    SWIFT_COMMAND=(swift)
fi

"${SWIFT_COMMAND[@]}" build -c release --arch arm64 --arch x86_64 --product AgentMeter
BIN_DIR="$("${SWIFT_COMMAND[@]}" build -c release --arch arm64 --arch x86_64 --show-bin-path)"
EXECUTABLE="$BIN_DIR/AgentMeter"
if [[ ! -x "$EXECUTABLE" ]]; then
    printf 'AgentMeter executable not found at %s\n' "$EXECUTABLE" >&2
    exit 1
fi
RESOURCE_BUNDLE="$BIN_DIR/AgentMeter_AgentMeter.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    printf 'AgentMeter resource bundle not found at %s\n' "$RESOURCE_BUNDLE" >&2
    exit 1
fi

SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK_PATH:-}"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    sparkle_framework_candidates=(
        "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.framework"
        "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64/Sparkle.framework"
        "$ROOT_DIR/.build/checkouts/Sparkle/Sparkle.framework"
    )
    for candidate in "$ROOT_DIR"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/*/Sparkle.framework; do
        sparkle_framework_candidates+=("$candidate")
    done
    for candidate in "${sparkle_framework_candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            SPARKLE_FRAMEWORK="$candidate"
            break
        fi
    done
fi
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
    printf 'Sparkle.framework was not found. Set SPARKLE_FRAMEWORK_PATH to its location.\n' >&2
    exit 1
fi

APP_DIR="$ROOT_DIR/.build/Agent Meter.app"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$FRAMEWORKS_DIR"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/AgentMeter"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
chmod 755 "$APP_DIR/Contents/MacOS/AgentMeter"

if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    SPARKLE_PLIST_KEYS=$(cat <<PLIST_KEYS
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
PLIST_KEYS
)
else
    SPARKLE_PLIST_KEYS=$(cat <<'PLIST_KEYS'
    <key>SURequireSignedFeed</key>
    <false/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <false/>
PLIST_KEYS
)
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>SUFeedURL</key>
    <string>${SPARKLE_FEED_URL}</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
${SPARKLE_PLIST_KEYS}
</dict>
</plist>
PLIST

APP_EXECUTABLE="$APP_DIR/Contents/MacOS/AgentMeter"
RPATH="@executable_path/../Frameworks"
if ! otool -l "$APP_EXECUTABLE" | grep -F "$RPATH" >/dev/null; then
    install_name_tool -add_rpath "$RPATH" "$APP_EXECUTABLE"
fi

if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$FRAMEWORKS_DIR/Sparkle.framework"
    codesign --force --deep --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
    codesign --force --deep --sign - --timestamp=none "$FRAMEWORKS_DIR/Sparkle.framework"
    codesign --force --deep --sign - --timestamp=none "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
