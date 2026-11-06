#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

swift build -c "$CONFIGURATION" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)"

APP="$ROOT/build/BrowserSelector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/BrowserSelector" "$APP/Contents/MacOS/BrowserSelector"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/BrowserSelector"

# ad-hoc 签名即可本地运行。若要避免每次重建后重新授权辅助功能，
# 请在 Xcode 里换成自己的开发团队签名，或使用固定的自签名证书。
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "已生成 $APP"
echo "运行：open \"$APP\""
