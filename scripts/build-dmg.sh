#!/bin/bash
# 构建 App 并打包成 build/FansCtrl-<版本>.dmg（含 Applications 快捷方式，拖拽安装）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="$ROOT/build/FansCtrl-${VERSION}.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fansctrl-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

cp -R build/FansCtrl.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
# macOS 27 起 hdiutil create 已弃用，优先用 diskutil image；旧系统没有该子命令时再回退
if diskutil image create from --help >/dev/null 2>&1; then
    diskutil image create from --format UDZO --volumeName "FansCtrl ${VERSION}" "$STAGE" "$DMG" >/dev/null
else
    hdiutil create -volname "FansCtrl ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
fi
codesign --force --sign - "$DMG"
hdiutil verify "$DMG" >/dev/null

echo "已生成 $DMG"
