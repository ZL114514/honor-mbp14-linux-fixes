#!/bin/bash
# 安装/卸载 DSDT 覆盖 (Arch, mkinitcpio acpi_override hook)
# 用法: sudo ./install-dsdt-override.sh install [dsdt_fixed.aml 路径]
#       sudo ./install-dsdt-override.sh remove
set -euo pipefail

OVERRIDE_DIR=/etc/initcpio/acpi_override
STOCK_CONF=/etc/mkinitcpio-stock.conf
STOCK_PRESET=/etc/mkinitcpio.d/linux-stock.preset

usage() { echo "用法: $0 {install [aml] | remove}"; exit 1; }
[ $# -ge 1 ] || usage

case "$1" in
install)
    AML="${2:-$(dirname "$0")/../patches/dsdt_fixed.aml}"
    [ -f "$AML" ] || { echo "找不到 $AML"; exit 1; }

    install -Dm644 "$AML" "$OVERRIDE_DIR/dsdt.aml"
    echo "[1/5] 已安装 $OVERRIDE_DIR/dsdt.aml"

    # HOOKS: acpi_override 必须在 autodetect 之前
    if ! grep -q 'acpi_override' /etc/mkinitcpio.conf; then
        sed -i 's/\bautodetect\b/acpi_override autodetect/' /etc/mkinitcpio.conf
        echo "[2/5] HOOKS 已加入 acpi_override"
    else
        echo "[2/5] HOOKS 已包含 acpi_override"
    fi

    # 救命镜像: 不带 acpi_override 的同版本 initramfs
    sed 's/acpi_override //' /etc/mkinitcpio.conf > "$STOCK_CONF"
    cat > "$STOCK_PRESET" <<'EOF'
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_config="/etc/mkinitcpio-stock.conf"
default_image="/boot/initramfs-linux-stock.img"
EOF
    echo "[3/5] 已生成救命镜像 preset ($STOCK_PRESET)"

    mkinitcpio -P
    echo "[4/5] initramfs 已重建"

    if lsinitcpio /boot/initramfs-linux.img 2>/dev/null | grep -q 'firmware/acpi/dsdt.aml'; then
        echo "[5/5] 校验通过: 补丁表已进入 /boot/initramfs-linux.img"
    else
        echo "[5/5] 警告: 未在 initramfs 中找到 dsdt.aml, 请用 lsinitcpio 手动确认"
    fi
    echo
    echo "完成。GRUB 里请确认存在 '原始DSDT-救命' 项 (见 docs/01-acpi-dsdt-fix.md 第 5 节)"
    ;;
remove)
    rm -f "$OVERRIDE_DIR/dsdt.aml"
    sed -i 's/\bacpi_override \?//g' /etc/mkinitcpio.conf
    rm -f "$STOCK_CONF" "$STOCK_PRESET" /boot/initramfs-linux-stock.img
    mkinitcpio -P
    echo "已卸载 DSDT 覆盖并重建 initramfs"
    ;;
*) usage ;;
esac
