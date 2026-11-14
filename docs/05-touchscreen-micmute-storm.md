# 触控屏伪键盘节点刷 KEY_MICMUTE：静音自翻转 / 指示灯狂闪 — 2026-11-14

> 状态：**已解决**。udev 规则让 libinput 忽略 FTSC1000 多出来的键盘节点，
> 触控节点与 Fn+F7 都不受影响。

## 1. 现象

触控屏修好并重启后（`docs/03`），空闲时麦克风静音状态会自己反复翻转，
`platform::micmute` 指示灯同步狂闪（约 60 Hz）。按一下 F7 或点一下屏幕会
短暂停下，随后继续；`wpctl` 有时采到 `[MUTED]`，有时采到正常，看起来像随机。

## 2. 根因：FTSC1000 的第二个 HID 集合被枚举成键盘

同一个 HID 设备 `0018:2808:5662`（触控屏）注册了两个 input 节点：

```
N: Name="FTSC1000:00 2808:5662"                  <- 真触控
S: Sysfs=.../0018:2808:5662.0007/input/input33
H: Handlers=event18 mouse4

N: Name="FTSC1000:00 2808:5662 UNKNOWN"          <- 伪键盘
S: Sysfs=.../0018:2808:5662.0007/input/input35
H: Handlers=kbd event19
```

`UNKNOWN` 节点的 keybit 只有 bit 248：

```
key bits: 0000000000000000 0000000000000000 0000000000000000 0100000000000000
```

即唯一的按键能力是 `KEY_MICMUTE`。控制器在空闲时持续发送同一份报文，
内核把它翻译成"麦克风静音键一直按着"：

```
$ sudo cat /dev/input/event19   # 60 秒抓包
1758 条 EV_KEY code=248 (KEY_MICMUTE) val=2
```

dmesg 里没有 `Unknown key`，因为 248 是已映射键；这也是它藏了很久的原因。

niri 把它当作 `XF86AudioMicMute`，命中 dms 的绑定
（`~/.config/niri/dms/binds.kdl`）：

```kdl
XF86AudioMicMute allow-when-locked=true { spawn "dms" "ipc" "call" "audio" "micmute"; }
```

于是每个报文都拉起一次 `dms ipc call audio micmute`，软件静音以报文频率翻转，
`audio-micmute` 触发器同步驱动指示灯。journal 里的 transient scope 数量就是
风暴的直接证据：修复前 15:21–15:29 每分钟 102–497 个
`Started app-niri-dms-*.scope`；修复后同一时段只剩手工测试的个位数。

触控与噪声互不影响：点屏幕时控制器改发真实触点报文，噪声短暂停止，
所以表现成"点一下会暂时停下"。

## 3. 排除项

| 假设 | 实测 | 结论 |
|---|---|---|
| LED 回环（写 brightness 触发按键） | 写 `platform::micmute/brightness` 六次，`event13` 无任何事件，静音不变 | 排除 |
| dms 自己在循环 | `dms ipc call audio micmute` 单次只翻转一次 | 排除 |
| EC / F7 路径 | 风暴期间 dmesg 无 `0x0287`/`0x0288`，`_Q14`/`_Q18` 只在真实 F7 时执行 | 排除 |

## 4. 修法：只让 libinput 忽略这个节点

规则文件 `scripts/70-honor-touchscreen-unknown-node.rules`：

```
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="FTSC1000:00 2808:5662 UNKNOWN", ENV{LIBINPUT_IGNORE_DEVICE}="1"
```

- 按**完整名字**匹配，触控节点的名字没有 `UNKNOWN` 后缀，不会误伤；
- 不按 `eventN` 匹配：睡眠唤醒会重建 HID 设备，event 号会变
  （本次实测 `event19` 重建后仍是 19，但 HID 实例从 `.0006` 变成 `.0007`，
  input 从 28 变成 35）；
- 规则是 `add|change`，所以开机、唤醒、手动 rebind 都会重新生效。

安装：

```bash
sudo ./scripts/install-touchscreen.sh install
```

`install-touchscreen.sh` 会安装规则并执行 `udevadm control --reload` +
`udevadm trigger`。注意：如果节点已经被合成器打开，修改 udev 属性不会让它
松手，需要重新登录/重启，或让触控服务 rebind 一次。

## 5. A/B 验证（真机，kernel 7.2.11-arch1-1）

| 检查项 | 修复前 | 修复后 |
|---|---|---|
| `udevadm info /dev/input/event19` | 无 `LIBINPUT_IGNORE_DEVICE` | `LIBINPUT_IGNORE_DEVICE=1` |
| niri 打开的 event 节点 | 同时有 `event18`、`event19` | 只有 `event18`（触控） |
| 60 秒静音/指示灯采样 | 持续翻转（journal 每分钟数百个 dms scope） | 0 次变化 |
| 内核侧 event19 报文 | 60 Hz | 仍是 60 Hz（只是没人消费） |
| 触控节点 | `event18` | `event18`，`Handlers=event18 mouse4` |

关键一步是强制 HID 重新枚举，证明规则在热插拔路径也生效：

```bash
echo 0018:2808:5662.0007 | sudo tee /sys/bus/hid/drivers/hid-multitouch/unbind
echo 0018:2808:5662.0007 | sudo tee /sys/bus/hid/drivers/hid-multitouch/bind
# niri 重新打开 event18，跳过 event19；udevadm info event19 -> IGNORE=1
```

随后执行 `touchscreen-up.sh --force`（与唤醒钩子同一条路径）：HID 设备重建为
`.0007`，`input33`/`input35`，规则依旧命中，niri 依旧只拿触控节点，静音保持稳定。
触摸、点击、滑动均正常。

## 6. 局限与后续

- 伪节点在**内核层**仍以 60 Hz 产生事件，只是不再进入 libinput/合成器；
  60 Hz 的 CPU 开销可以忽略，但更彻底的做法是给 `hid-multitouch` 加
  collection 级 quirk，让内核根本不注册这个 input 节点。目前没有现成 quirk，
  且用户态规则已足够解决问题，故不引入内核补丁。
- `KEY_MICMUTE` 本身仍由 `Huawei WMI hotkeys`（`event13`）正常提供，
  Fn+F7 的 `0x0288` 缺失问题不受本修复影响，见 `docs/04`。

## 7. 回滚

```bash
sudo rm /etc/udev/rules.d/70-honor-touchscreen-unknown-node.rules
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=input
```

或 `sudo ./scripts/install-touchscreen.sh remove`（会同时卸载触控服务）。
回滚后伪节点重新进入 libinput，风暴与闪灯会回来。
