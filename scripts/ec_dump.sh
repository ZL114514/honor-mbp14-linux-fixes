#!/bin/bash
# EC RAM 快照 / 对比工具
# 用法:  sudo ./ec_dump.sh save <名字>     保存快照
#        sudo ./ec_dump.sh diff <名1> <名2> 对比两份快照
set -e
DIR="/home/zl/honor-dsdt/ec"
mkdir -p "$DIR"
modprobe ec_sys 2>/dev/null || true

snapshot() {
    local out="$DIR/ec_$1.hex"
    /usr/bin/dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=256 2>/dev/null | xxd > "$out"
    echo "已保存: $out"
}

case "${1:-}" in
    save)
        [ -n "${2:-}" ] || { echo "用法: $0 save <名字>"; exit 1; }
        snapshot "$2"
        ;;
    diff)
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "用法: $0 diff <名1> <名2>"; exit 1; }
        diff -u "$DIR/ec_$2.hex" "$DIR/ec_$3.hex" || true
        ;;
    *)
        echo "用法: $0 {save <名字>|diff <名1> <名2>}"
        ;;
esac
