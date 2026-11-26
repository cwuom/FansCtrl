#!/bin/bash
# 构建 release 版本并组装 build/FansCtrl.app（ad-hoc 签名）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
if ! grep -q "version = \"$VERSION\"" Sources/FanCore/BuildInfo.swift; then
    echo "版本不一致：Info.plist 为 $VERSION，请同步 Sources/FanCore/BuildInfo.swift" >&2
    exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/FansCtrl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/FansCtrlApp" "$APP/Contents/MacOS/FansCtrl"
cp "$BIN/fanctld" "$BIN/fanctl" "$APP/Contents/MacOS/"
cp Support/install.sh Support/uninstall.sh Support/AppIcon.icns "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/"*.sh
# 图标由 scripts/make-icon.swift 生成并提交在 Support/ 中，构建时无需重新绘制

# 先签内部可执行文件，再签外层 App
for exe in fanctld fanctl; do
    codesign --force --options runtime --sign - "$APP/Contents/MacOS/$exe"
done
# 强化运行时下向访达发送 Apple 事件需要显式授权
codesign --force --options runtime --entitlements Support/FansCtrl.entitlements --sign - "$APP/Contents/MacOS/FansCtrl"
codesign --force --options runtime --entitlements Support/FansCtrl.entitlements --sign - "$APP"
codesign --verify --strict "$APP"

echo "已生成 $APP"
