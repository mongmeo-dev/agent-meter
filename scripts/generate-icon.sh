#!/usr/bin/env bash
# Regenerates artwork/AppIcon.icns from artwork/AppIcon.svg. Requires rsvg-convert and iconutil.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/artwork/AppIcon.svg"
OUTPUT="$ROOT_DIR/artwork/AppIcon.icns"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w "$size" -h "$size" "$SOURCE" -o "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    rsvg-convert -w "$double" -h "$double" "$SOURCE" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil --convert icns --output "$OUTPUT" "$ICONSET"
printf 'Created %s\n' "$OUTPUT"
