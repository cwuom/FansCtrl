#!/bin/bash
# 安装 FansCtrl 后台服务（需 root）。用法：sudo install.sh [二进制目录]
# 默认从 App 包内 Contents/MacOS 取 fanctld / fanctl。
set -euo pipefail

LABEL="com.fansctrl.daemon"
HELPER="/Library/PrivilegedHelperTools/${LABEL}"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
CLI="/usr/local/bin/fanctl"
LOG_DIR="/Library/Logs/FansCtrl"

if [[ $EUID -ne 0 ]]; then
    echo "需要管理员权限：sudo $0" >&2
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${1:-$DIR/../MacOS}"
for bin in fanctld fanctl; do
    if [[ ! -x "$BIN_DIR/$bin" ]]; then
        echo "找不到 $BIN_DIR/$bin" >&2
        exit 1
    fi
done

# 旧版本收到 SIGTERM 会先把风扇交还系统再退出
launchctl bootout "system/${LABEL}" 2>/dev/null || true

install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools "$LOG_DIR" /usr/local/bin
install -m 755 -o root -g wheel "$BIN_DIR/fanctld" "$HELPER"
install -m 755 -o root -g wheel "$BIN_DIR/fanctl" "$CLI"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HELPER}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- 只在异常退出（崩溃）时重启；收到 SIGTERM 正常退出前会先交还风扇控制 -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/fanctld.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
launchctl enable "system/${LABEL}"

for _ in 1 2 3 4 5; do
    if "$CLI" status >/dev/null 2>&1; then
        echo "FansCtrl 后台服务已启动"
        exit 0
    fi
    sleep 1
done
echo "服务已安装，但暂未响应，请查看 ${LOG_DIR}/fanctld.log" >&2
exit 1
