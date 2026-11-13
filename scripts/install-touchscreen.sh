#!/bin/bash
# Install/remove the touchscreen boot service + resume hook.
# Usage: sudo ./install-touchscreen.sh install|remove|status
set -euo pipefail

LIB=/usr/local/lib/honor-touchscreen
UNIT=/etc/systemd/system/honor-touchscreen.service
HOOK=/usr/lib/systemd/system-sleep/honor-touchscreen
SRC=$(cd "$(dirname "$0")" && pwd)

need() { command -v "$1" >/dev/null || { echo "缺少 $1 ($2)"; exit 1; }; }

case "${1:-}" in
install)
    need i2ctransfer i2c-tools
    need modprobe kmod
    modinfo acpi_call >/dev/null 2>&1 || { echo "缺少 acpi_call 模块 (pacman -S acpi_call)"; exit 1; }

    install -Dm755 "$SRC/touchscreen-up.sh" "$LIB/touchscreen-up.sh"
    install -Dm644 "$SRC/touchscreen.service" "$UNIT"
    install -Dm755 "$SRC/touchscreen-sleep-hook.sh" "$HOOK"

    systemctl daemon-reload
    systemctl enable honor-touchscreen.service
    systemctl restart honor-touchscreen.service
    echo "--- 状态 ---"
    systemctl --no-pager --lines=8 status honor-touchscreen.service || true
    ;;
remove)
    systemctl disable --now honor-touchscreen.service 2>/dev/null || true
    rm -f "$UNIT" "$HOOK"
    rm -rf "$LIB"
    systemctl daemon-reload
    echo "已卸载（触控屏在下次重启前仍可用）"
    ;;
status)
    systemctl --no-pager --lines=8 status honor-touchscreen.service || true
    echo "--- 绑定 ---"
    readlink -f /sys/bus/i2c/devices/i2c-FTSC1000:00/driver || echo "未绑定"
    echo "--- input ---"
    grep -A3 'Name="FTSC1000' /proc/bus/input/devices || echo "无 input 节点"
    ;;
*)
    echo "用法: $0 {install|remove|status}"; exit 1
    ;;
esac
