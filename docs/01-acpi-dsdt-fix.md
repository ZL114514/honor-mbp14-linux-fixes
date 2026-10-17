# DSDT 补丁 · 改动汇总与救援手册

**机器**：Honor MagicBook Pro 14 (FMB-P) · Intel Core Ultra 5 225H (Arrow Lake-H) · BIOS 1.13 (INSYDE, 2025-05-08)
**系统**：Arch Linux 7.1.5-arch1-2 · root = btrfs `/dev/nvme0n1p5` · `/boot` = FAT32 EFI 分区 UUID `<VOLID>`
**补丁文件**：`~/honor-dsdt/dsdt_fixed.aml`（原厂表 `dsdt_stock.aml`）

---

## 0. 一句话
厂商 DSDT 里有一句非法的**模块级**赋值，Linux 加载整张 DSDT 时直接 Abort（`_SB.PC00` 子树全丢 → 触控板/电池/GPIO/I2C 全废）。
补丁 = 把那 14 个 AML 字节改成 Noop，通过 initramfs 早期 ACPI 覆盖（`acpi_override`）生效。

---

## 1. 补丁前的症状（存档）
```
dmesg | grep -c "ACPI BIOS Error"   -> 182
ACPI Error: No pointer back to namespace node in package     (dsargs-472)
ACPI Error: AE_AML_INTERNAL, [DSDT] table load failed        (tbxfload-322)
Final data object initialization: Namespace contains 9 objects   (正常应为 5765)
```
- 触控板不存在：`/proc/bus/input/devices` 里无 `TPD0`，无 i2c-designware 适配器
- `intel-lpss 0000:00:15.0/.1/.2: probe with driver intel-lpss failed`（`PCI INT A: not connected`）
- `/sys/class/power_supply` 为空（没有 BAT0）
- `pinctrl_intel` / `i2c_hid_acpi` / `hid_multitouch` 全未加载

## 2. 根因
`Device (NFC0)` 内有一句写在设备级（table load 时立即执行，本应放在 `_CRS` 里）的赋值：

```asl
CreateWordField (SBGF, 0x17, INT1)
INT1 = GNUM (0x0014080A)      ; <-- 厂商 bug
```

`GNUM -> GINF` 对「方法返回的 Package 副本」做二次 `Index()`：
ACPICA 在 `dsargs.c` 报 `No pointer back to namespace node in package` → AE_AML_INTERNAL →
**整张 DSDT 判为加载失败**。Windows 对模块级代码错误只忽略不改判，所以 Windows 一切正常。

## 3. 到底改了什么（全部改动，就这 5 处）

| # | 位置 | 改动 |
|---|---|---|
| 1 | DSDT AML 文件偏移 **0x72CA5**，14 字节 | `70 47 4E 55 4D 0C 0A 08 14 00 49 4E 54 31`（`Store(GNUM(0x0014080A), INT1)`）→ **14 × `A3`（Noop）** |
| 2 | DSDT 头 offset 24 `OEM Revision` | `2` → `3` |
| 3 | DSDT 头 offset 9 `checksum` | 重算，使全表字节和 % 256 == 0 |
| 4 | 新增 `/etc/initcpio/acpi_override/dsdt.aml` | 补丁表本体 |
| 5 | `/etc/mkinitcpio.conf` 的 `HOOKS` | `base systemd autodetect ...` → `base systemd acpi_override autodetect ...` |

附加（救命用，不影响启动）：
- `/etc/mkinitcpio-stock.conf` + `/etc/mkinitcpio.d/linux-stock.preset` → 生成**无覆盖**的 `/boot/initramfs-linux-stock.img`
- `/boot/grub/custom.cfg` 增加 3 个菜单项（见 §5）

**没做的事**：没有重编译 DSDT、没有搬动任何硬编码地址（GNVS/NVSA/SANB/PNVB/OGNS/MDBG 全部原样）、OEM ID `HONOR` / OEM Table ID `ARL` 保持不变。
（你 2025-08 那版 `/boot/dsdt.aml` 起不来，正是因为它把这些硬编码地址整体挪了 0x10000：`0x67E23D18 -> 0x67E13D18`，等于让系统读错内存。）

影响范围：只丢了 NFC0 的静态 GPIO pin 赋值（`NFC0._STA` 返回 0，本机不用 NFC，无影响）。
触控板自己的 pin 由 `_INI`/`_CRS` 在运行时用 `GNUM(GPDI)` 现算，不受影响。

## 4. 已验证（userspace，用 acpiexec 复现/确认，不用重启）
```
acpiexec -b quit ~/honor-dsdt/dsdt_fixed.aml
  -> Namespace contains 5765 objects                      (补丁前 9)
  -> \_SB.PC00.I2C1.TPD0._HID = "PNP0C50"
  -> \_SB.PC00.I2C1.TPD0._CRS = I2cSerialBus 0x2C @ \_SB.PC00.I2C1
                              + GpioInt \_SB.GPI0 pin 0x79 (121)
```
initramfs 内嵌表已校验 sha256 = `45802b78b8eac184751d9bfdee1f6eb089361ee6a3df23f053442d9da71c9d2f`（528211 字节）。
`/boot/initramfs-linux-stock.img` 内**不含** dsdt.aml（已确认）。

## 5. 挂了怎么救

### A. GRUB 菜单（最快）
开机 → GRUB 菜单里选：
- **`Arch Linux (原始DSDT-救命)`** → 用无覆盖的 initramfs，回到打补丁前状态（可正常进系统）
- **`Arch Linux (recovery shell, init=/bin/bash)`** → 带补丁的救援 shell
- **`Arch Linux (recovery shell, 原始DSDT)`** → 不带补丁的救援 shell

看不到菜单：开机时按住 `Shift` 或连按 `Esc`。

### B. 救援 shell 里彻底关掉补丁
```bash
mount -o remount,rw /
rm -f /etc/initcpio/acpi_override/dsdt.aml
sed -i 's/ acpi_override//' /etc/mkinitcpio.conf
mkinitcpio -P
reboot -f
```
（不改 HOOKS 也行，`acpi_override` 钩子在目录为空时只会报 "No ACPI table override files found!" 而生成镜像是成功的——保险起见还是删掉。）

### C. 从 Windows 救
`/boot` 就是 FAT32 的 EFI 分区（UUID `<VOLID>`），Windows 资源管理器里能直接看到 `initramfs-linux*.img`。
把 `initramfs-linux-stock.img` 复制成 `initramfs-linux.img` 即可（等价于回滚覆盖）。
`/etc` 在 btrfs 根分区里，Windows 上看不到；要改就用 §B 的 GRUB 救援项。

### D. 备份清单（都在 D 盘）
```
D:\DSDT-FIX-RECOVERY.md          <- 本文件
D:\DSDT-FIX-BACKUP\grub.cfg      <- 改动前的 /boot/grub/grub.cfg
D:\DSDT-FIX-BACKUP\custom.cfg    <- 改动前的 /boot/grub/custom.cfg
D:\DSDT-FIX-BACKUP\mkinitcpio.conf
D:\DSDT-FIX-BACKUP\dsdt_stock.aml
```

## 6. 重启后验收
```bash
dmesg | grep -c "ACPI BIOS Error"                    # 应从 182 大幅下降
dmesg | grep -iE "i2c_hid|designware|pinctrl-intel"  # 应出现 i2c_hid_acpi / hid-multitouch / pinctrl
grep -B2 -A12 TPD0 /proc/bus/input/devices           # 应出现触控板（含 ABS_MT_* 能力）
ls /sys/class/power_supply/                          # 应出现 BAT0（电池）
ls /sys/bus/i2c/devices/ | grep designware           # 应有 i2c-designware-master 适配器
```

## 7. 万一触控板还是不出现
`TPD0._INI` 会按 EC 变量 `TPDT` 把 `_HID` 改成厂商 ID（`SYNA2393` / `06CB2846` / `GXTP7863` / `ELAN9048`）。
本机 `i2c_hid_acpi` 模块 alias 只有 `acpi*:PNP0C50:*` 和 `acpi*:ACPI0C50:*`，但 `_CID` 仍是 `PNP0C50`，理论上照样能匹配。

若真不匹配：
```bash
echo i2c-PNP0C50:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/bind
# 或做一个 DSDT 补丁：让 _INI 不覆盖 _HID（把 _HID = "xxx" 那几行也 Noop 掉）
```

## 8. 后续维护
- 内核升级时 `mkinitcpio -P` 会**同时**重建 `initramfs-linux.img`（带补丁）和 `initramfs-linux-stock.img`（不带），救命项不会过期。
- BIOS 升级后需重做补丁（偏移可能变，用 §9 脚本自动定位）。
- 想让补丁彻底消失：删 `/etc/initcpio/acpi_override/dsdt.aml`、从 HOOKS 去掉 `acpi_override`、删 `linux-stock.preset` 与 `/etc/mkinitcpio-stock.conf`，然后 `mkinitcpio -P`。

## 9. 复现脚本（换 BIOS / 重装后）
```bash
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.dat
sudo pacman -S --needed acpica
python3 - <<'PY'
import struct
d = bytearray(open('dsdt.dat','rb').read())
pat = bytes([0x70]) + b'GNUM' + bytes([0x0C,0x0A,0x08,0x14,0x00]) + b'INT1'
i = bytes(d).find(pat)
assert i > 0, 'pattern not found: BIOS 可能已修，或偏移/常量变了'
d[i:i+len(pat)] = b'\xa3' * len(pat)
struct.pack_into('<I', d, 24, 3)
d[9] = 0
d[9] = (-sum(d)) & 0xFF
open('dsdt_fixed.aml','wb').write(d)
print('patched at', hex(i))
PY
acpiexec -b quit dsdt_fixed.aml | grep "Namespace contains"    # 期望 5765 objects
```
