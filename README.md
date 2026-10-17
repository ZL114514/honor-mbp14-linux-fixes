# honor-mbp14-linux-fixes

> HONOR MagicBook Pro 14 (FMB-P, Intel Core Ultra 5 225H) 在 Arch Linux 下的修复集：
> 原厂 ACPI DSDT 二进制补丁、蓝牙、热区，以及触控屏的完整调查记录。

## 机器

| 项 | 值 |
|---|---|
| 型号 | HONOR MagicBook Pro 14 (FMB-P) |
| CPU | Intel Core Ultra 5 225H (Arrow Lake-H) |
| BIOS | 1.13 (INSYDE) |
| 系统 | Arch Linux (kernel 7.1.5-arch1-2) |
| 触控板 | `BLTP7853` @ `\_SB.PC00.I2C1.TPD0`, I2C `0x2C` |
| 触控屏 | `FTSC1000` @ `\_SB.PC00.I2C2.TPL1`, I2C `0x38` |
| 电池 | `BAT0` / `ADP1` |

## 修复结果

| 项目 | 修复前 | 修复后 |
|---|---|---|
| **触控板** | 完全不存在（无 HID 设备） | ✅ `BLTP7853` + hid-multitouch |
| **电池** | `/sys/class/power_supply` 为空 | ✅ `BAT0` + `ADP1` |
| **热区** | 4 个 | ✅ 13 个（SEN1-7 / TCPU / pch / iwi…） |
| **ACPI 错误** | 182 条 `ACPI BIOS Error` + 整表加载失败 | ✅ 3 条 |
| **内核驱动栈** | `intel-lpss` / `pinctrl-intel` / `i2c-hid` 全部 probe 失败 | ✅ 正常 |
| **蓝牙** | `bluetooth.service` 未启用、无 `bluetoothctl` | ✅ `hci0` powered |
| **触控屏** | 不存在 | ❌ 未解决（见下方） |

## 一、根因：原厂 DSDT 存在致命 AML 错误

内核日志：

```
ACPI Error: No pointer back to namespace node in package  (dsargs-472)
ACPI Error: AE_AML_INTERNAL, [DSDT] table load failed      (tbxfload-322)
Namespace contains 9 objects          <-- 正常应为 5765
```

问题代码在 `Device (NFC0)` 里的一条**模块级**语句：

```asl
CreateWordField (SBGF, 0x17, INT1)
INT1 = GNUM (0x0014080A)
```

`GNUM → GINF` 会对"方法返回的 Package 副本"再做 `Index()`，ACPICA 因此抛
`AE_AML_INTERNAL`，**整张 DSDT 被判加载失败** → `\_SB.PC00` 整棵子树消失 →
触控板、电池、GPIO、热区全部陪葬。

Windows 对模块级 AML 错误采取"忽略继续"，所以只有 Linux 中招。

### 修法：14 字节 Noop 补丁

在偏移 `0x72CA5`（BIOS 1.13）把这条 Store 指令改成 14 个 `Noop(0xA3)`，
表长、所有设备路径、NVS 地址全部不变，然后 OEM Revision +1 并重算校验和：

```
原始: 70 47 4E 55 4D 0C 0A 08 14 00 49 4E 54 31   (Store(GNUM(0x0014080A), INT1))
改为: A3 A3 A3 A3 A3 A3 A3 A3 A3 A3 A3 A3 A3 A3
```

验证：`acpiexec -b quit dsdt_fixed.aml` → `Namespace contains 5765 (0x1685) objects`

> ⚠️ 不要用 GRUB 的 `acpi /dsdt.aml`：那是另一张表，NVS 地址整体偏移了
> `0x10000`，挂上去会直接起不来。必须走 initramfs 的 `acpi_override`。

### 安装

```bash
# 1) 从运行中的机器导出原厂表
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt_stock.aml
# 2) 打补丁（本仓库自带已验证过的 patches/dsdt_fixed.aml，也可自己生成）
python3 patches/patch_dsdt.py dsdt_stock.aml dsdt_fixed.aml
# 3) 装进 initramfs（会同时生成"原始DSDT-救命"镜像）
sudo ./scripts/install-dsdt-override.sh install patches/dsdt_fixed.aml
```

细节与回滚：见 [`docs/01-acpi-dsdt-fix.md`](docs/01-acpi-dsdt-fix.md)

### 验证

```bash
sudo dmesg | grep -c "ACPI BIOS Error"          # 182 -> 3
grep -A12 TPD0 /proc/bus/input/devices          # 出现触控板
ls /sys/class/power_supply/                     # BAT0 ADP1
ls /sys/class/thermal/thermal_zone* | wc -l     # 13
```

## 二、蓝牙

硬件和固件一直是好的（`ibt-0093-4150.sfi` 正常加载），问题只是软件：

```bash
sudo pacman -S bluez-utils
sudo systemctl enable --now bluetooth
```

## 三、热区

DSDT 修好后 ACPI thermal zone 从 4 个补全到 13 个：
`SEN1`~`SEN7`（Intel DPTF 虚拟传感器）、`TCPU`/`TCPU_PCI`、`x86_pkg_temp`、
`acpitz`、`INT3400 Thermal`、`iwlwifi_1`。风扇曲线与过热降频策略自此有数据可用
（可选 `thermald`）。

## 四、触控屏：未解决（完整调查记录）

硬件是好的（Windows 侧注册表有 `ACPI\FTSC1000\2` 与 3 个 HID collection，
其中 `Col01` 是 `HID_DEVICE_UP:000D_U:0004` Touch Screen），但 **Linux 下控制器
在 I2C 上完全不应答**。

已排除：

| 可能原因 | 排除依据 |
|---|---|
| I2C 地址不对 | bus2 上 `0x08`~`0x77` 全地址只读扫描，0 应答（对照 bus1 的 NFC 正常）|
| 上电时序 / 初始化缺失 | S3 睡眠唤醒后面板重新上电，仍 NAK |
| EC 软件开关 | 管家开关 = EC `0x45` 的 `DETP`/`GTPS` 位；Linux 本来就处于"开"状态（`0x45=0x01`）|
| EC 那两个位是电源门控 | EC 端口写 + **MMIO `0xFE0B0045`**（= DSDT 的真实路径）+ 6 种 `TPON×DETP` 组合轮询，均无效果 |
| ACPI 电源管理 | `FTSC1000` 无 `_PS0/_PS3/power_state` |
| AML 里有触控屏电源/复位控制 | DSDT + 全部 26 个 SSDT 翻完，`T1PE/T1PR/T1IP/T1EP/T1RP` 等"使能"变量在 AML 里零引用 |

结论：控制器大概率**有电但信号到不了**（I2C2 引脚 mux）或供电走 EC 私有通道。
完整时间线与数据见 [`docs/02-touchscreen-investigation.md`](docs/02-touchscreen-investigation.md)。

## 目录结构

```
docs/01-acpi-dsdt-fix.md              ACPI 修复全过程 + 回滚/救援手册
docs/02-touchscreen-investigation.md  触控屏调查记录
patches/patch_dsdt.py                 可复现的 DSDT 二进制修补器
patches/dsdt_fixed.aml                已打补丁并验证的 DSDT (BIOS 1.13)
scripts/install-dsdt-override.sh      安装/卸载 initramfs ACPI 覆盖
scripts/ec_dump.sh                    EC RAM 快照/对比工具
data/ec/                              EC 256 字节快照（Linux / Windows 开 / Windows 关）
data/pinctrl/pins_linux.txt           PCH GPIO 289 个 pad 的 mode + PADCFG 全表
```

## 数据文件说明

- `data/ec/ec_win_touch_on.hex` / `ec_win_touch_off.hex`
  Windows 下用 RWEverything 抓的 EC 转储，触控开 / 关两态。**唯一**差异是
  `0x45`: `0x01`（开）↔ `0x07`（关，`DETP=1 GTPS=1`），即荣耀电脑管家的
  "触控屏"开关在 EC 侧的实现。
- `data/ec/ec_linux_touchdead.hex`
  Linux 下（触控屏无响应）的 EC 快照，`0x45=0x01` —— 与 Windows"开"的状态一致。
- `data/pinctrl/pins_linux.txt`
  `/sys/kernel/debug/pinctrl/INTC105E:00/pins` 全量导出，含每个 pad 的
  `mode(PMODE)` 与 PADCFG 原始值，可用于对照引脚复用状态。

## 免责声明

DSDT 覆盖属于固件层修改。本仓库的做法**只改一条指令的 14 字节**、不重排表结构、
不动 NVS 地址，并且保留了原版 initramfs 的救援启动项。即便如此，刷写前请自行
确认机型/BIOS 版本一致，并准备好救援 U 盘。

MIT License
