#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${CONFIG:-release}"

if [ ! -f "$ROOT/web/index.html" ]; then
  echo "error: web/index.html 缺失，请先运行 make web" >&2
  exit 1
fi

swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path --package-path "$ROOT")"

APP="$ROOT/dist/DeepmacOS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DeepmacOS" "$APP/Contents/MacOS/DeepmacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

rsync -a --delete "$ROOT/web/" "$APP/Contents/Resources/web/"

if [ -f "$ROOT/vendor/chat-demo/LICENSE" ]; then
  cp "$ROOT/vendor/chat-demo/LICENSE" "$APP/Contents/Resources/LICENSE"
fi
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (ad-hoc)"
echo "built: $APP"
