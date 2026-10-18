# 触控屏 (FTSC1000) 调查记录 — 2026-10-17

## 结论：驱动链路没问题，是触控控制器不响应 I2C（没上电/没出复位）

### 硬件与 ACPI
- 面板触控：`\_SB.PC00.I2C2.TPL1`，`_HID` 运行时被 _INI 改为 **FTSC1000**（EC 变量 TPLT==1），`_CID` = PNP0C50
- I2C2 = PCI 00:15.2 (designware.2)，从地址 **0x38**，`hid-descr-addr` = 1（_DSM HIDG 返回 HID2=1）
- 中断：GpioInt → `\_SB.GPI0`，pin 由 `GNUM(TPGI)` 现算（TPGI = GNVS 里 T1GI）
- Windows 侧证据：注册表有 `ACPI\FTSC1000\2`、`HID\FTSC1000&Col01/02/03`，
  Col01 = HID_DEVICE_UP:000D_U:0004（**Touch Screen**），绑定 hidi2c.inf；
  最近一次 setupapi 记录 2026-10-06 → 硬件存在且在 Windows 下工作过

### Linux 侧实测
```
i2c-FTSC1000:00 已由 ACPI 创建，i2c_hid_acpi 能匹配并 probe
probe 卡在 i2c_hid_probe_address() → 设备 NAK → ENXIO（"nothing at this address"）
i2ctransfer -y 2 r4@0x38          -> Remote I/O error (NAK)
i2ctransfer -y 2 w1@0x38 0x00     -> NAK
15 次重试（150ms 间隔）            -> 全 NAK
i2cdetect -a -y 2                 -> 地址全空
对照: i2ctransfer -y 1 r4@0x57    -> 读到 NFC 数据 (bus1 正常)
对照: i2ctransfer -y 1 r4@0x2c    -> "Device or resource busy" (触控板已绑定)
```
- 没有 i2c_designware 超时日志 → 控制器/pad 正常，是设备目标不应答
- 面板 DPMS off/on 重上电后仍 NAK
- 强制 `bind` 仍 ENXIO

### 已排除
- EC 变量（ACPI EC RAM）：
  - `0x40` bit4 `TPON` = 0
  - `0x45` bit0 `TPMD`=1, bit1 `DETP`=0, bit2 `GTPS`=0（GTPS=0 表示 EC 认为触控屏是"启用"）
  - 试写 TPON=1（0x40: 0x65→0x75）→ EC 发 WMI 通知 0x02A3，但 0x38 仍 NAK
  - 试写 DETP=1（0x45: 0x01→0x03）→ EC 自己把 GTPS 置 1（= 禁用），说明 DETP=1 是"关闭"，已还原
  - 结论：EC 层不是 blocker，已全部还原为 0x40=0x65 / 0x45=0x01
- 驱动匹配、_DSM、hid-descr-addr、GPIO 控制器 (gpiochip0 = meteorlake-pinctrl, 451 pins) 均正常

### 待验证 / 下一步
1. **重启进 Windows，用手指点屏幕**，确认现在是否还能触控（决定性）
2. 若能触控 → 说明是 Linux 少走了一步电源/复位序列：
   - 用 RWEverything 在 Windows 下对比 EC 0x40/0x45 与 GPIO 相关寄存器
   - 或对照 Windows 的 ACPI 方法调用（GTPS/STPS/GTSS/STSS 是 Honor WMI 的触控开关）
3. 若不能触控 → 面板排线/硬件问题，或该 SKU 本就不带触控


---

## 补充：荣耀管家那个开关是怎么实现的（2026-10-17 晚）

### Windows 侧
- UI/配置：`Honor/PCManager/plugins/MagicTouchPadPlugin.dll`
  - 注册表 `\SOFTWARE\PCManager\TouchScreenSetting`，键名 `screenenable`
- 硬件动作：`Util.dll` 用 `ROOT\WMI` 的 **`OemWMIMethod`** 作用在 `ACPI\PNP0C14\HWMI_0`（PNP0C14 = Honor WMI 设备）
- 分发逻辑在 **SSDT16**（`_SB.WMI1` 的 WMI 方法分发器）：
  - class 0x02 + SFID `0x0F` → `GTPS`（get）、`0x10` → `STPS`（set）
  - class 0x02 + SFID `0x14` → `GTSS`、`0x15` → `STSS`
- DSDT 侧实现（`\GTPS/\STPS/\GTSS/\STSS`）只做两件事：
  - `STPS`：写 EC RAM `0x40` bit4 `TPON`
  - `STSS`：写 EC RAM `0x45` bit1 `DETP`

### 实测（Linux，已全部还原）
| 操作 | 结果 |
|---|---|
| `TPON`=1（0x40: 0x65→0x75） | EC 发出 WMI 通知 0x02A3，但 0x38 仍 NAK |
| `TPON`=1 + `DETP`=1（0x45: 0x01→0x03） | EC 自己把 `GTPS` 置 1（= 禁用），说明 DETP=1 是"关"，仍 NAK |
| 面板 DPMS 重上电 | 无权写 dpms，无效 |
| bus2 全地址 write-probe（0x2c/0x38/0x3c/0x5d/0x70/0x10/0x14） | 全 NAK |
| bus1 @0x2c write-probe（已知触控板） | **ACK**（对照组证明 write-probe 有效） |

→ 结论：管家的开关只改这两个 EC 位，**不是触控屏电源门控**；控制器依旧完全不应答。

### EC 快照工具
```bash
sudo ~/honor-dsdt/ec_dump.sh save <名字>
sudo ~/honor-dsdt/ec_dump.sh diff <名1> <名2>
```
基线：`~/honor-dsdt/ec/ec_linux_touchdead.hex`（也备份在 `D:\DSDT-EC-BACKUP\`）

### 待做实验
1. Windows 里把管家开关**关掉**，再摸屏幕 —— 如果照样能触控，说明这个开关是 Windows 软件层禁用，跟硬件供电无关。
2. Windows 里把开关关→开（最后一次是"开"），然后**重启**（不要关机断电）进 Arch，
   跑 `sudo ~/honor-dsdt/ec_dump.sh save win_on` 和 `diff linux_touchdead win_on`：
   - 有差异 → 找到真正的门控位，可复刻
   - 无差异 → 问题在 I2C2 引脚 mux 或面板供电，与 EC 无关

## S3 睡眠唤醒复测（2026-10-17 20:17）
```
面板重新上电后 0x38 读/写探针 → 仍然 Remote I/O error (NAK)
bus2 全地址扫 → 全空
i2c_hid_acpi 绑定 → 失败
HID 设备仍只有 Telink dongle + 触控板 0018:347D:7853
```
→ 面板掉电重上电也救不回来，说明不是"上电时序/初始化缺失"问题。

## 当前最终判断
- ACPI / EC / WMI 三条路都翻遍：**没有任何一处控制触控屏电源**
  （T1PE/T1PR 等"使能"变量在 AML 里零引用；SSDT 里无上电时序）
- I2C2 控制器活着（NAK 而非 timeout），但总线上没有任何设备应答
- 剩下两种可能：
  1. **I2C2 引脚没被 mux**（BIOS/Windows 驱动配了，Linux 没配）→ 器件在，但信号到不了
  2. **触控模块的供电被 EC 私有命令/GPIO 门控**，只认 Windows 端专有流程 → 器件没电
- 区分这两者需要读 **GPI0 pad 寄存器（PADCFG）**：/dev/mem 被 STRICT_DEVMEM 挡住，
  需要写个小内核模块来读（或 Windows 侧用 RWEverything 对照）

## 全地址只读扫描（2026-10-17 20:30）
```
bus2: 0x08..0x77 逐地址 i2ctransfer r1 → 全部无应答（0 个设备）
对照 bus1 @0x57 (NFC) → 读到 0x1d  ✅ 方法有效
```
→ I2C2 上**一个设备都没有**（不是 0x38 地址错，是整条总线空的）。

## pad 模式可以直接从 debugfs 读（不用写内核模块）
`/sys/kernel/debug/pinctrl/INTC105E:00/pins` 每行格式：
```
pin 0 (PECI) 0:INTC105E:00 mode 1 0x40000700 0x0003c000 0x00000000 [ACPI]
```
含 **mode(PMODE)** + PADCFG 原始值，289 个脚。分布：mode1=122, mode2=10, mode3=5, mode4=1, GPIO=...
但 ARL-H 的 I2C0-5 脚在驱动表里是 `GPP_C_x` 之类通用名（没有 I2C2_SDA 这种名字），
所以没法只靠名字定位 I2C2 的那两个 pad ——要对照得靠 Windows 侧 dump。

## 结论（阶段性收尾）
- I2C2 总线在 Linux 下完全没有设备应答；控制器本身正常（NAK 非 timeout）
- 全地址扫描排除"地址不对"，S3 唤醒排除"上电时序"，EC/WMI 排除"软件开关"
- ACPI/SSDT 里没有任何触控屏电源或复位控制（26 个 SSDT 全查）
- 最可能：**触控模块供电走 EC 私有通道/非 ACPI 门控**，只认 Windows 端专有流程
- 若要继续：需要 Windows 侧 RWEverything 同时 dump
  （EC 0x00-0xFF + GPI0 MMIO `0xE0D10000/0xE0D20000/0xE0D30000`）再和 Linux 侧
  `/sys/kernel/debug/pinctrl/INTC105E:00/pins` 做对照


## 补充：计划 A（直接改 pad mux）为什么行不通

尝试用 `/dev/mem` 直接读写 PCH GPIO 的 PADCFG 寄存器：

```
open /dev/mem, lseek 0xE0D10000 -> read -> EPERM (Operation not permitted)
```

原因：GPIO 三个 community（`0xE0D10000/0xE0D20000/0xE0D30000`）已登记在
`/proc/iomem` 的 `INTC105E:00` 名下并被 pinctrl 驱动占用，`/dev/mem` 对
driver-claimed 区域一律拒绝（`0xFE0B0000` 那个 EC 窗口没被占用，所以能读）。

改用 `/dev/gpiochip0`（libgpiod）可以看到 451 条线：**406 input / 44 output**，
44 条 output 全是 BIOS/EC 驱动的使能脚（`GPP_C_5/C_8/C_15`、`GPP_A_12/A_20`、
`GPP_E_2/E_6`、`GPP_H_0/1/2/19`、`GPP_F_19/20/21`、`GPP_B_*`、`CNV_BTEN`…），
且 `gpioinfo` 里**没有任何 consumer**。

关键推理：**这些 pad 的电平是 BIOS 在 POST 时设好的，与后面启动哪个 OS 无关**。
Windows 能用触控，说明这个电平状态本身就"对"；在 Linux 里把它翻过来只可能
弄坏别的东西，不可能揭示根因。所以计划 A 从逻辑上就不成立，已放弃。

## 唯一还有意义的对照实验

需要 Windows 侧同一批 GPIO 寄存器（64KB × 3 community）的 dump，与 Linux 的
`data/pinctrl/pins_linux.txt` 逐 pad 对比，**专门找"Windows 驱动成输出、
Linux 却是输入"的 pad** —— 那才是 Windows 多做的动作（比如把触控 RESET 拉高）。

RWEverything 的 Memory 窗口地址是 **64 位**，必须输入完整 16 位十六进制：

```
00000000E0D10000   -> gpio_c1.bin
00000000E0D20000   -> gpio_c2.bin
00000000E0D30000   -> gpio_c3.bin
```

（第一次抓的 `ME0D10000...rw` 就是因为只填了 8 位，被当成 `E0D1000000000000`，全 0。）


## 最终的 GPIO 对照尝试（失败，且说明原因）

Windows 侧用 RWEverything 抓了三个 community，但 **RW 的 Memory 窗口一次只保存一屏
0x100 字节**（不是 64KB），得到的只有 community 头部寄存器：

```
E0D10000: 00 00 96 00 40 03 00 00 FF FF FF FF 00 06 00 00 ...
E0D20000: 00 00 96 00 40 03 00 00 FF FF FF FF 00 06 00 00 ...   (与上仅差 1 字节)
E0D30000: 00 00 96 00 18 03 00 00 FF FF FF FF 00 06 00 00 ...
```

（GPIO 中断状态/使能寄存器，三个 community 几乎一样）

拿 Linux `pins` 表里 208 个不同的 PADCFG 值去匹配这 256 字节 —— 除了 0x00000000
以外没有任何命中，**说明 pad 配置寄存器不在这 0x100 字节里**（pad 区在 community
更靠后的偏移）。RW 要抓满 64KB 需要翻 256 屏，不现实。

即使抓到完整 64KB，期望值也有限：**pad 电平是 BIOS 在 POST 时设死的，与启动哪个
OS 无关**。真正有意义的只是"Windows 驱动主动驱动了某个 pad"，而这个假说没有任何
旁证（Linux 侧 `gpioinfo` 显示 451 条线无任何 consumer）。

## 触控屏最终结论

- 硬件存在且在 Windows 下工作（注册表 `ACPI\FTSC1000\2` + 3 个 HID collection，
  `Col01` = `HID_DEVICE_UP:000D_U:0004` Touch Screen）
- Linux 侧：ACPI 节点 → i2c client → `i2c_hid_acpi` 链路全部正常，但设备在 I2C2 上
  **完全不 ACK**（全地址扫描 0 应答）
- EC 状态与 Windows"触控开"完全一致（`0x45=0x01`），且 EC 两个开关位经端口与 MMIO
  两条路径写入均无效 —— 说明它不是电源门控
- DSDT + 26 个 SSDT 中没有任何触控屏电源/复位控制
- 结论：**触控模块的供电/复位走 EC 私有通道或面板内部时序，Linux 侧无法触达**。
  在拿到厂商 EC 协议或面板时序文档之前，无法修复。
