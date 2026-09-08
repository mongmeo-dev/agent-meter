#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${APP_VERSION:-${VERSION:-${1:-}}}"
if [[ -z "$VERSION" ]]; then
    printf 'Usage: APP_VERSION=1.2.3 %s\n' "${BASH_SOURCE[0]}" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'APP_VERSION must be a stable semantic version (for example, 1.2.3): %s\n' \
        "$VERSION" >&2
    exit 1
fi

APP_DIR="${APP_DIR:-$ROOT_DIR/.build/Agent Meter.app}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/.build/dist}"
ARCHIVE_NAME="${ARCHIVE_NAME:-agent-meter-${VERSION}.zip}"
RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-v${VERSION}}}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/mongmeo-dev/agent-meter/releases/download/${RELEASE_TAG}/${ARCHIVE_NAME}}"
RELEASE_TITLE="${RELEASE_TITLE:-Agent Meter ${VERSION}}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"

if [[ -z "$SPARKLE_PRIVATE_KEY" ]]; then
    printf 'SPARKLE_PRIVATE_KEY is required to create a release\n' >&2
    exit 1
fi
if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    printf 'SPARKLE_PUBLIC_KEY is required for a signed release\n' >&2
    exit 1
fi
if [[ ! -d "$APP_DIR" ]]; then
    printf 'Application bundle not found at %s\n' "$APP_DIR" >&2
    exit 1
fi

APP_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$APP_DIR/Contents/Info.plist")"
if [[ "$APP_BUNDLE_VERSION" != "$VERSION" ]]; then
    printf 'CFBundleVersion %s does not match release version %s\n' \
        "$APP_BUNDLE_VERSION" "$VERSION" >&2
    exit 1
fi
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
        "$APP_DIR/Contents/Info.plist")"
    if [[ "$APP_PUBLIC_KEY" != "$SPARKLE_PUBLIC_KEY" ]]; then
        printf 'Application public key does not match SPARKLE_PUBLIC_KEY\n' >&2
        exit 1
    fi
fi

SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$SPARKLE_SIGN_UPDATE" ]]; then
    sparkle_sign_update_candidates=(
        "$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
        "$ROOT_DIR/.build/checkouts/Sparkle/bin/sign_update"
    )
    for candidate in "${sparkle_sign_update_candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            SPARKLE_SIGN_UPDATE="$candidate"
            break
        fi
    done
fi
if [[ -z "$SPARKLE_SIGN_UPDATE" || ! -x "$SPARKLE_SIGN_UPDATE" ]]; then
    printf 'Sparkle sign_update was not found. Set SPARKLE_SIGN_UPDATE to its path.\n' >&2
    exit 1
fi

mkdir -p "$RELEASE_DIR"
ARCHIVE_PATH="$RELEASE_DIR/$ARCHIVE_NAME"
APPCAST_PATH="$RELEASE_DIR/appcast.xml"
rm -f "$ARCHIVE_PATH" "$APPCAST_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

SIGNATURE_OUTPUT="$(
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" |
        "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$ARCHIVE_PATH"
)"
SIGNATURE_RE='sparkle:edSignature="([^"]+)"[[:space:]]+length="([0-9]+)"'
if [[ ! "$SIGNATURE_OUTPUT" =~ $SIGNATURE_RE ]]; then
    printf 'Sparkle sign_update did not return archive signature metadata\n' >&2
    exit 1
fi
ARCHIVE_SIGNATURE="${BASH_REMATCH[1]}"
ARCHIVE_LENGTH="${BASH_REMATCH[2]}"
if [[ ! "$ARCHIVE_SIGNATURE" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    printf 'Sparkle returned an invalid archive signature\n' >&2
    exit 1
fi
ACTUAL_LENGTH="$(stat -f%z "$ARCHIVE_PATH")"
if [[ "$ARCHIVE_LENGTH" != "$ACTUAL_LENGTH" ]]; then
    printf 'Sparkle archive length %s does not match %s\n' \
        "$ARCHIVE_LENGTH" "$ACTUAL_LENGTH" >&2
    exit 1
fi

SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
ARCHIVE_SIGNATURE="$ARCHIVE_SIGNATURE" \
ARCHIVE_PATH="$ARCHIVE_PATH" xcrun swift - <<'SWIFT'
import CryptoKit
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let publicKeyData = Data(base64Encoded: environment["SPARKLE_PUBLIC_KEY"] ?? ""),
      let signature = Data(base64Encoded: environment["ARCHIVE_SIGNATURE"] ?? ""),
      let path = environment["ARCHIVE_PATH"] else {
    fatalError("Invalid update verification inputs")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
guard publicKey.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the application's public key\n", stderr)
    exit(1)
}
SWIFT

xml_escape() {
    local value="$1"
    # Assignment context preserves whitespace; outer quotes change escaping in Bash 3.
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&apos;}
    printf '%s' "$value"
}

ESCAPED_TITLE="$(xml_escape "$RELEASE_TITLE")"
ESCAPED_DOWNLOAD_URL="$(xml_escape "$DOWNLOAD_URL")"
ESCAPED_RELEASE_URL="$(xml_escape "https://github.com/mongmeo-dev/agent-meter/releases/tag/${RELEASE_TAG}")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Agent Meter</title>
    <link>https://github.com/mongmeo-dev/agent-meter/releases</link>
    <description>Agent Meter updates</description>
    <language>en</language>
    <item>
      <title>${ESCAPED_TITLE}</title>
      <link>${ESCAPED_RELEASE_URL}</link>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
          url="${ESCAPED_DOWNLOAD_URL}"
          sparkle:edSignature="${ARCHIVE_SIGNATURE}"
          length="${ARCHIVE_LENGTH}"
          type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

printf '%s\n' "$SPARKLE_PRIVATE_KEY" |
    "$SPARKLE_SIGN_UPDATE" --ed-key-file - --disable-signing-warning "$APPCAST_PATH" >/dev/null
printf '%s\n' "$SPARKLE_PRIVATE_KEY" |
    "$SPARKLE_SIGN_UPDATE" --ed-key-file - --verify "$ARCHIVE_PATH" "$ARCHIVE_SIGNATURE" >/dev/null
printf '%s\n' "$SPARKLE_PRIVATE_KEY" |
    "$SPARKLE_SIGN_UPDATE" --ed-key-file - --verify "$APPCAST_PATH" >/dev/null

printf 'Created %s\nCreated %s\n' "$ARCHIVE_PATH" "$APPCAST_PATH"
