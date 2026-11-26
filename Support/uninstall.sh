#!/bin/bash
# 卸载 FansCtrl 后台服务（需 root）。服务退出时会把风扇交还系统自动控制。
set -euo pipefail

LABEL="com.fansctrl.daemon"

if [[ $EUID -ne 0 ]]; then
    echo "需要管理员权限：sudo $0" >&2
    exit 1
fi

launchctl bootout "system/${LABEL}" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/${LABEL}.plist" \
      "/Library/PrivilegedHelperTools/${LABEL}" \
      "/usr/local/bin/fanctl" \
      "/var/run/${LABEL}.sock"
rm -rf "/Library/Application Support/FansCtrl" "/Library/Logs/FansCtrl"
echo "FansCtrl 后台服务已卸载，风扇由系统控制"
