# honor-mbp14-linux-fixes

> HONOR MagicBook Pro 14 (FMB-P, Intel Core Ultra 5 225H) 在 Arch Linux 下的修复集：
> 原厂 ACPI DSDT 二进制补丁、蓝牙、热区、触控屏（SSDT 电源资源挂错节点的绕行方案），
> 以及 Fn+F7 麦克风静音键的定位记录。

## 机器

| 项 | 值 |
|---|---|
| 型号 | HONOR MagicBook Pro 14 (FMB-P) |
| CPU | Intel Core Ultra 5 225H (Arrow Lake-H) |
| BIOS | 1.13 (INSYDE) |
| 系统 | Arch Linux (kernel 7.2.11-arch1-1) |
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
| **触控屏** | 不存在（0x38 全程 NAK） | ✅ 已解决（见第四节 / `docs/03`）|
| **Fn+F7 麦克风** | 能静音，再按不恢复 | ⚠️ 根因已定位、修复未刷（见 `docs/04`）|

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

## 四、触控屏：已解决

**根因不在驱动，也不在 EC，而是厂商 SSDT 把电源资源挂错了父节点。**

触控屏的真实节点是 `\_SB.PC00.I2C2.TPL1`（`FTSC1000`，FocalTech `2808:5662`），
但触控屏的电源资源 `PTPL` 定义在 `SSDT20` 的 `\_SB.PC00.I2C5` 作用域下：

```asl
Scope (\_SB.PC00.I2C5)
{
    PowerResource (PTPL, ...)         { _ON { 上电; 释放复位; 配中断 } }
    Scope (TPL1) { ... _PR0 → PTPL }  // 本 SKU 没有 I2C5，这行开机就 AE_NOT_FOUND
}
```

于是 ACPI 从不调用 `PTPL._ON`，BIOS 留在复位脚 `GPP_A_12` 的低电平一直不撤，
芯片不 ACK。现场执行一次 `_ON` 即可点亮：

```
T1PE = 0x140813 → GPIO 179 (GPP_H_19)  电源使能，开机已为 1
T1PR = 0x14040c → GPIO 108 (GPP_A_12)  复位，开机为 0  ← 卡在这里
T1GI = 0x14040b → GPIO 107 (GPP_A_11)  中断

PTPL._ON 后: GPP_A_12 0x84000200 → 0x84000201，0x38 立刻 ACK
bind i2c-FTSC1000:00 → hid-multitouch 2808:5662，出现 /dev/input/eventN
```

开机 + 唤醒自动完成这一步：

```bash
sudo ./scripts/install-touchscreen.sh install
```

一个 oneshot 服务调 `PTPL._ON` 并绑定驱动，一个 `systemd-sleep` 钩子在唤醒后
重跑（`--force`，因为 D3 回来时驱动可能还挂着但设备已死）。全部幂等，
`install-touchscreen.sh remove` 可完全卸载。

根因推导、寄存器取证与 A/B 验证见
[`docs/03-touchscreen-solved.md`](docs/03-touchscreen-solved.md)；
早期"电源走 EC 私有通道"的错误结论存档在
[`docs/02-touchscreen-investigation.md`](docs/02-touchscreen-investigation.md)
（错在只 grep 了 DSDT，而引用在 SSDT20 里且用了别名）。

## 五、Fn+F7 麦克风静音

第一次按 F7（未静音 → 静音）走 EC `_Q14`，WMI 事件码 `0x0287`，
`huawei-wmi` 映射为 `KEY_MICMUTE`，正常静音。
再按一次走 `_Q18`，事件码 **`0x0288`**，驱动表里没有这一项：

```
input input14: Unknown key pressed, code: 0x0288
```

事件在 `input_handle_event()` 就被丢掉，用户态（evdev/hwdb/自定义守护进程）
都拿不到，所以永远解不了静音。EC 上报的是**动作结果**，不是按键动作，
所以两个码都要映射成 `KEY_MICMUTE`。

修法二选一（都还没应用）：

1. 驱动加 DMI quirk（推荐，不动固件）；
2. DSDT 单字节补丁：`_Q18` 的 `0x0288` → `0x0287`，
   用 `patches/patch_fn_f7.py` 生成，已离线验证反编译与校验和，未真机启动。

注意：上游内核正在把 `0x0288` 映射成 `KEY_CAMERA_ACCESS_TOGGLE`（别的 Honor
机型的摄像头快门键），**升级内核不能修好这台机器**，反而可能误触发摄像头开关。

细节见 [`docs/04-fn-f7-micmute.md`](docs/04-fn-f7-micmute.md)。
临时恢复：`wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0`。

## 目录结构

```
docs/01-acpi-dsdt-fix.md              ACPI 修复全过程 + 回滚/救援手册
docs/02-touchscreen-investigation.md  触控屏早期调查（结论已作废，存档）
docs/03-touchscreen-solved.md         触控屏根因、取证与开机/唤醒自动化
docs/04-fn-f7-micmute.md              Fn+F7 只能静音不能恢复：0x0288 未被映射
patches/patch_dsdt.py                 可复现的 DSDT 二进制修补器
patches/patch_fn_f7.py                _Q18 0x0288 -> 0x0287 单字节补丁生成器（未刷）
patches/dsdt_fixed.aml                已打补丁并验证的 DSDT (BIOS 1.13)
scripts/install-dsdt-override.sh      安装/卸载 initramfs ACPI 覆盖
scripts/touchscreen-up.sh             调 PTPL._ON + 绑定 i2c-hid（幂等）
scripts/touchscreen.service           开机 oneshot 单元
scripts/touchscreen-sleep-hook.sh     唤醒后重跑的 systemd-sleep 钩子
scripts/install-touchscreen.sh        安装/卸载开机服务与唤醒钩子
scripts/ec_dump.sh                    EC RAM 快照/对比工具
data/acpi/SSDT20-tplptl.dsl           SSDT20 里挂错父节点的电源资源原文
data/ec/                              EC 256 字节快照（Linux / Windows 开 / Windows 关）
data/i2c/ftsc1000-hid-descriptor.txt  _ON 之后读到的 HID 描述符（VID/PID 自证）
data/pinctrl/pins_linux.txt           PCH GPIO 289 个 pad 的 mode + PADCFG 全表
data/pinctrl/touchscreen_pads.txt     复位/电源/中断三个 pad 的 _ON 前后对照
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
