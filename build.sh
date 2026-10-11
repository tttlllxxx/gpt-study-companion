#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/GPT 学习伴侣.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

if [[ ! -f "$SCRIPT_DIR/node_modules/marked/lib/marked.umd.js" || ! -f "$SCRIPT_DIR/node_modules/dompurify/dist/purify.min.js" ]]; then
  cd "$SCRIPT_DIR"
  npm ci
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
ICONSET_DIR="$SCRIPT_DIR/.build/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" "$SCRIPT_DIR/assets/app-icon.png" \
    --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}.png" > /dev/null
  retina_size=$((icon_size * 2))
  sips -z "$retina_size" "$retina_size" "$SCRIPT_DIR/assets/app-icon.png" \
    --out "$ICONSET_DIR/icon_${icon_size}x${icon_size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$SCRIPT_DIR/assets/AppIcon.icns"
TARGET_ARCH="${TARGET_ARCH:-$(uname -m)}"
swiftc \
  "$SCRIPT_DIR/StudyCompanion.swift" \
  -parse-as-library \
  -target "$TARGET_ARCH-apple-macosx13.0" \
  -o "$MACOS_DIR/GPTStudyCompanion" \
  -framework AppKit \
  -framework WebKit
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/node_modules/marked/lib/marked.umd.js" "$RESOURCES_DIR/marked.umd.js"
cp "$SCRIPT_DIR/node_modules/dompurify/dist/purify.min.js" "$RESOURCES_DIR/purify.min.js"
cp "$SCRIPT_DIR/chat-attachment.js" "$RESOURCES_DIR/chat-attachment.js"
cp "$SCRIPT_DIR/chat-composer.js" "$RESOURCES_DIR/chat-composer.js"
cp "$SCRIPT_DIR/reader.css" "$RESOURCES_DIR/reader.css"
cp "$SCRIPT_DIR/reader-navigation.js" "$RESOURCES_DIR/reader-navigation.js"
cp "$SCRIPT_DIR/examples/Welcome.md" "$RESOURCES_DIR/Welcome.md"
cp "$SCRIPT_DIR/assets/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
mkdir -p "$RESOURCES_DIR/Licenses"
cp "$SCRIPT_DIR/node_modules/marked/LICENSE.md" "$RESOURCES_DIR/Licenses/marked.txt"
cp "$SCRIPT_DIR/node_modules/dompurify/LICENSE" "$RESOURCES_DIR/Licenses/DOMPurify.txt"
chmod +x "$MACOS_DIR/GPTStudyCompanion"
codesign --force --deep --sign - "$APP_DIR"

echo "Built: $APP_DIR"
