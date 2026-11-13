# Fn+F7 麦克风静音：能静音，按第二下不恢复 — 2026-11-14

> 状态：**根因已定位，修复未应用**（固件补丁已验证可生成，见第 5 节）。
> 当前手动恢复：`wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0`。

## 1. 现象

- 麦克风未静音时按 `Fn+F7`：正常静音，PipeWire 源静音，指示灯亮。
- **再按 F7：没有任何效果**，麦克风一直静音，指示灯常亮。
- `dmesg` 每次按下都有：

```
input input14: Unknown key pressed, code: 0x0288
```

## 2. 根因：EC 用两个不同的事件码表示"静音"和"解除静音"

DSDT 的 EC 查询方法里，F7 由两条独立的 query 处理：

```asl
Method (_Q14) { ^^^^WMI1.WMEN = 0x0287; Notify (WMI1, 0xA0) }   // 静音
Method (_Q18) { ^^^^WMI1.WMEN = 0x0288; Notify (WMI1, 0xA0) }   // 解除静音
```

`huawei-wmi` 只映射了前者：

```
0x0287 -> 248 (KEY_MICMUTE)
0x0288 -> <无>
```

所以第二次按下产生的事件被内核当作未知键**直接丢弃**，桌面系统收不到任何
按键，自然解不了静音。EC 侧（以及指示灯）已经切回"未静音"，但 OS 的
软件静音状态还停在 1。

从 `dmesg` 能看到这个模型：连续按三下 F7，三条记录全是 `0x0288`
（只有从"未静音"切到"静音"的那一次才是 `0x0287`）。也就是说 **EC 上报的是
动作完成后的状态，不是"按了一下"** —— 所以两个码必须都映射成 `KEY_MICMUTE`，
不能指望"按下去/抬起来"成对出现。

## 3. 证据

### 3.1 驱动键表里确实没有 0x0288

```bash
sudo python3 - <<'PY'
import fcntl, struct
EVIOCGKEYCODE_V2 = 0x80284504
fd = open('/dev/input/event12', 'rb')       # Huawei WMI hotkeys
for idx in range(30):
    buf = bytearray(struct.pack('BBHI', 1, 4, idx, 0) + b'\x00'*32)
    try:
        fcntl.ioctl(fd, EVIOCGKEYCODE_V2, buf)
        _, _, index, keycode = struct.unpack('BBHI', buf[:8])
        print(f"idx={index}: scancode=0x{struct.unpack('I', buf[8:12])[0]:04x} -> {keycode}")
    except OSError:
        break
PY
```

```
idx=0: 0x0281 -> 224 (KEY_BRIGHTNESSDOWN)
idx=1: 0x0282 -> 225
idx=2: 0x0284 -> 113
idx=3: 0x0285 -> 114
idx=4: 0x0286 -> 115
idx=5: 0x0287 -> 248 (KEY_MICMUTE)
idx=6: 0x0289 -> 238
idx=7: 0x028a -> 171
idx=8: 0x028b -> 444
idx=9: 0x028e -> 210
idx=10: 0x02c1 -> 0
```

（内核 7.2.11-arch1-1）

### 3.2 用户态改不了

- `EVIOCSKEYCODE(0x0288 -> KEY_MICMUTE)` 返回 `EINVAL`：evdev 只能修改
  **表里已存在**的 scancode，不能新增。`60-keyboard.hwdb` 的
  `KEYBOARD_KEY_0288=micmute` 走的正是这个 ioctl，因此同样无效。
- 也没有 `MSC_SCAN` 可抓：`0x0288 = 648` 超出该设备 `KEY` 位图范围
  （该输入设备的 keybit 只到 447），事件在 `input_handle_event()` 里就被丢了，
  `evtest` / 自定义守护进程都看不到。

结论：这一层只能改**驱动键表**或**DSDT 事件码**。

## 4. 注意：升级内核并不能修好

上游 2026-08 的提交 `885b55bcd2`（"add camera toggle keycode"）确实给
`huawei_wmi_keymap[]` 加了一条 `0x288`，但映射的是
`KEY_CAMERA_ACCESS_TOGGLE`，测试机型是 Honor MagicBook X14 Plus (FMI-76)，
在那台机器上 `0x288` 是 `Fn+F8` 摄像头电控快门。

**同一事件码在不同 Honor 机型上含义不同**。对 FMB-P 来说 `0x0288` 是
"麦克风已解除静音"，套用上游那条会变成触发摄像头隐私开关。
所以：

- 不要把它当成通用修复；
- 驱动侧要加的话必须用 DMI quirk 只匹配 FMB-P。

## 5. 两种修法

### 5.1 推荐：驱动加 DMI quirk（未实现）

在 `drivers/platform/x86/huawei-wmi.c`：

```c
static const struct dmi_system_id huawei_quirks[] = {
    ...
    {
        .callback = dmi_matched,
        .ident = "HONOR FMB-P",
        .matches = {
            DMI_MATCH(DMI_SYS_VENDOR, "HONOR"),
            DMI_MATCH(DMI_PRODUCT_NAME, "FMB-P"),
        },
        .driver_data = &quirk_fmbp,      // quirk 里记 "0x288 也是 micmute"
    },
```

按键分发处（`huawei_wmi_input_notify` → `sparse_keymap_report_event`）对
`quirks->micmute_0x288` 且 `obj->integer.value == 0x288` 的情况改报 `0x287`。
好处：不动固件、可上游、可卸载。

### 5.2 备选：DSDT 单字节补丁（已生成，未刷）

把 `_Q18` 里唯一的 `Store(0x0288, ^^^^WMI1.WMEN)` 改成 `0x0287`：

```bash
python3 patches/patch_fn_f7.py patches/dsdt_fixed.aml dsdt_fnfix.aml
# 命中偏移: 0x3BCC4, 0x88 -> 0x87
# 已写出: dsdt_fnfix.aml (528211 字节, 校验和 0x86)
```

已验证（离线）：

| 检查项 | 结果 |
|---|---|
| 与原表差异 | 只有 2 字节：`0x3BCC4`(`0x88`→`0x87`) 和表头校验和 `0x9`(`0x85`→`0x86`) |
| 表长 / 所有偏移 | 不变（528211 字节）|
| `iasl -d` 反编译 | `_Q18` 变成 `^^^^WMI1.WMEN = 0x0287` |
| 校验和 | 全表求和 `% 256 == 0` |

刷法同 DSDT 补丁：把它当作 `acpi_override` 的 `dsdt.aml` 重新生成 initramfs。
**尚未在真机上启动验证。**

为什么不优先：改固件影响所有 OS，且这两个码在别的 Honor 机型上含义不同，
固件层写死之后没有回退余地（只能换回原表重启）。

## 6. 当前可用的手动恢复

```bash
# 解除默认录音源的软件静音
wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0
# 某些客户端（如浏览器）持有独立节点，需要一起解
wpctl status | sed -n '/Sources:/,/Filters:/p'
wpctl set-mute <id> 0
```

注意这只是把 OS 侧状态掰回来，EC 与按键的下一次 `0x0288` 仍然会被丢弃；
所以**每静音一次就要手动解一次**，直到上面任一补丁落地。

静音指示灯 `/sys/class/leds/platform::micmute` 由 `huawei-wmi` 注册
（`default_trigger = "audio-micmute"`），实测跟随**软件**静音状态：
解除静音后 `brightness=0`，再静音后回到 `1`。它不能用来判断 EC 侧状态。
