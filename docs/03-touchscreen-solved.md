# 触控屏修复：SSDT 电源资源挂错父节点 — 2026-11-14

> 状态：**已解决并可复现**。根因是厂商 SSDT 把触控屏的 ACPI 电源资源
> `PTPL` 挂在 `I2C5`（本 SKU 不存在）下面，而真实的触控屏在 `I2C2`。
> 因此 `PTPL._ON` 永远没人调用，复位脚 `GPP_A_12` 一直拉低，芯片不 ACK。
> 用户在本次会话中第一次真正点亮了这块屏。

## 1. 一句话结论

`\_SB.PC00.I2C2.TPL1`（`FTSC1000`，FocalTech `2808:5662`）并非"没电"或
"信号到不了"：**电源已经由 BIOS 打开，缺的只是拉高复位脚**。拉高复位脚的
AML 方法只存在于一张挂错父节点的 SSDT 里，Linux 下用 `acpi_call` 手动调它
即可点亮，随后 `i2c_hid_acpi` 正常 probe。

## 2. 证据链

### 2.1 开机日志里三条"孤儿"引用

```
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.I2C3.TPD0], AE_NOT_FOUND
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.I2C4.TPL1], AE_NOT_FOUND
ACPI BIOS Error (bug): Could not resolve symbol [\_SB.PC00.I2C5.TPL1], AE_NOT_FOUND
```

本机型只有 I2C0/I2C1/I2C2 三个 PCI 功能（`00:15.0/.1/.2`）。SSDT20 按
"通用模板"为 I2C3/4/5 各写了一份 `Scope (TPL1) { ... }`，但这三个设备节点
根本不存在。`PTPL`（PowerResource）本身能创建成功，**但没有任何设备引用它**：

```asl
Scope (\_SB.PC00.I2C5)
{
    PowerResource (PTPL, 0x00, 0x0000)
    {
        Method (_STA) { Return (GGOV (TPPE)) }            // 电源使能脚电平
        Method (_ON)  { SGOV (TPPE, TPEP);   Sleep (2)     // 上电
                        SGOV (TPPR, TPRP);                 // 释放复位
                        ONTM = Timer
                        SGRA (TPI2, TPIP) }                // 中断脚
        Method (_OFF) { ... 相反方向 ... }
    }
    Scope (TPL1) { Name (TD_P, Package { PTPL }) ... _PR0/_PR3 → TD_P }   // ← 挂错
}
```

真实设备在 `\_SB.PC00.I2C2.TPL1`，它的 `_PR0` 不存在 → ACPI 从不给这个设备
上电，`_ON` 永不执行。

### 2.2 GNVS 里的引脚号与开机电平

`PTPL._ON` 用的三个变量来自 GNVS（`T1PE/T1PR/T1GI`），用 `acpi_call` 读出：

| 变量 | 值 | 解码后 GPIO | 用途 |
|---|---|---|---|
| `\T1PE` | `0x140813` | GPIO 179 = `GPP_H_19` | 电源使能 |
| `\T1PR` | `0x14040c` | GPIO 108 = `GPP_A_12` | 复位（低有效） |
| `\T1GI` | `0x14040b` | GPIO 107 = `GPP_A_11` | HID 中断 |
| `\T1EP` / `\T1RP` | `0x1` / `0x1` | — | `_ON` 时写入的有效电平 |

开机后的实际 pad 状态（`/sys/kernel/debug/pinctrl/INTC105E:00/pins`）：

```
pin 122 (GPP_H_19) 179: GPIO 0x84000201  -> 电源已开
pin 65  (GPP_A_12) 108: GPIO 0x84000200  -> 复位=0，芯片被按在复位里
```

`GGOV(T1PE)=1`、`GGOV(T1PR)=0` 与 pad 值互相印证。此时 `i2ctransfer -y 2 w1@0x38 0x00`
→ `Remote I/O error`（NAK）。

### 2.3 调用 `PTPL._ON` 之后

```bash
echo '\_SB.PC00.I2C5.PTPL._ON' | sudo tee /proc/acpi/call
# 0x0
pin 65 (GPP_A_12) 108: GPIO 0x84000201   # 复位释放
i2ctransfer -y 2 w2@0x38 0x01 0x00 r30@0x38
```

设备立刻用 HID 描述符回答，且内容自证身份：

```
1e 00 | 00 01 | dd 01 | 02 00 | 03 00 | 42 00 | 04 00 | 42 00
05 00 | 06 00 | 08 28 | 62 56 | 02 62 | 00 00
```

- `wHIDDescLength=0x001E`、`bcdVersion=0x0100`
- `wReportDescLength=0x01DD`(477 B)、`wReportDescRegister=0x0002`
- `wVendorID=0x2808`、`wProductID=0x5662` → 正是内核枚举出的 `2808:5662`

绑定驱动：

```bash
echo i2c-FTSC1000:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/bind
```

```
hid-multitouch 0018:2808:5662.000B: input,hidraw3:
  I2C HID v1.00 Device [FTSC1000:00 2808:5662] on i2c-FTSC1000:00
```

出现两个 input 节点（触摸 + 一个 vendor collection），IRQ 走 `intel-gpio 107`。
绑定后 `i2ctransfer` 报 `faulty argument is 'w1@0x38'` 属于正常现象 ——
该地址已被驱动占用，不是故障。

## 3. 为什么上一轮调查得出了错误结论

`docs/02` 里写"`T1PE/T1PR/T1IP/T1EP/T1RP` 在 AML 里零引用"。这句话只对了一半：

- 这些名字在 **DSDT 里确实没有引用**；
- 但引用在 **SSDT20** 里，且用的是**别名** `TPPE/TPPR/TPIP/TPEP/TPRP/TPI2`：
  `TPPE = T1PE /* External reference */`。

按变量名 grep DSDT 自然一无所获，于是误判成"电源/复位走 EC 私有通道"。
真正的判据是 **ACPI 命名空间里 `PTPL` 有没有被挂到真实设备上**，以及
**`GGOV(T1PR)` 的实时值**，而不是"源码里出现过没有"。

## 4. 固化：开机 + 唤醒自动执行

不重刷任何表。用一个 oneshot 服务在开机时调 `PTPL._ON` 并绑定驱动，
再用 systemd-sleep 钩子在唤醒后重来一遍。

```bash
sudo ./scripts/install-touchscreen.sh install   # 安装 + 启用 + 立即执行
sudo ./scripts/install-touchscreen.sh status    # 查看服务/绑定/input 节点
sudo ./scripts/install-touchscreen.sh remove    # 卸载
```

安装的东西：

| 路径 | 作用 |
|---|---|
| `/usr/local/lib/honor-touchscreen/touchscreen-up.sh` | 实际动作，幂等 |
| `/etc/systemd/system/honor-touchscreen.service` | 开机 oneshot（`multi-user.target`）|
| `/usr/lib/systemd/system-sleep/honor-touchscreen` | 唤醒后 `touchscreen-up.sh --force` |

脚本逻辑（`scripts/touchscreen-up.sh`）：

1. 等 `i2c-FTSC1000:00` 出现（最多 10 s；EC 把触控屏关掉时直接退出 0）
2. 已绑定且非 `--force` → 直接退出（幂等）
3. `modprobe acpi_call`，执行 `\_SB.PC00.I2C5.PTPL._ON`
4. 轮询 `i2ctransfer w1@0x38 0x00`（最多 10 次 / 1 s），NAK 则报错退出
5. `echo i2c-FTSC1000:00 > .../i2c_hid_acpi/bind`

`--force` 用于唤醒路径：先 unbind 再重来。**必须 force** —— 从 D3 回来时
驱动可能还挂着但设备已死，仅看"是否绑定"会误判为正常。

依赖：`acpi_call`（本机 `1.2.2-395`，内核模块在 `extramodules/`）、`i2c-tools`。

## 5. 验证记录（A/B 实测）

| 步骤 | pad 108 (`GPP_A_12`) | `0x38` | 驱动 |
|---|---|---|---|
| 初始（BIOS 留的状态）| `0x84000200` | NAK | 未绑定 |
| `PTPL._ON` | `0x84000201` | ACK | 未绑定 |
| `bind` | `0x84000201` | 占用 | `i2c_hid_acpi` |
| `PTPL._OFF` + `unbind` | `0x84000200` | NAK | 未绑定 |
| `systemctl restart honor-touchscreen` | `0x84000201` | ACK | `i2c_hid_acpi` |
| `system-sleep` 钩子（`--force`）| `0x84000201` | ACK | `i2c_hid_acpi` |

`_ON` 是幂等的（只写 1，不产生复位脉冲），重复执行不会打断已工作的设备。
`_OFF` 只用于验证，没有装进任何服务。

服务日志（从上面第 5 行那次冷启动状态拉起）：

```
touchscreen-up: calling \_SB.PC00.I2C5.PTPL._ON
touchscreen-up: PTPL._ON -> 0x0
touchscreen-up: 0x38 ACK on i2c-2
touchscreen-up: bound: FTSC1000:00
touchscreen-up: input: FTSC1000:00 2808:5662 (input79)
```

绑定瞬间内核会打印一条 `i2c_hid_acpi i2c-FTSC1000:00: failed to change power
setting.`，来自 `acpi_device_set_power(D0)`：真实设备 `TPL1` 没有 `_PR0`
（还是那个挂错节点的问题），但 `i2c-hid` 继续 probe，功能不受影响。

## 6. 更彻底的做法（未采用，未验证）

把 SSDT20 里 `Scope (\_SB.PC00.I2C5)` 下的 `Scope (TPL1)` 改成
`Scope (\_SB.PC00.I2C2)`，让 `_PR0` 真正挂到设备上。这样 ACPI 会在设备
进入 D0 时自动 `_ON`，不再需要用户态脚本，S3 唤醒也由 ACPI 负责。

不采用的原因：

- 需要在 `acpi_override` 里同时替换 DSDT 和 SSDT20（两张表、两套校验和），
  风险和工作量都远大于一个 oneshot 服务；
- SSDT20 长度 40 KB 左右，字节级改动会影响表内 `External` 解析顺序，
  必须重新用 `iasl` 编译并整体替换，无法像 DSDT 那样只改 14 字节；
- 当前方案已经实测可用，且卸载只需 `systemctl disable`。

## 7. 回滚

```bash
sudo ./scripts/install-touchscreen.sh remove
```

之后触控屏回到"不可用但无害"状态（`i2c_hid_acpi` probe 失败，仅一条 ENXIO，
不影响启动）。想临时点亮仍然可以手动执行 `touchscreen-up.sh`。
