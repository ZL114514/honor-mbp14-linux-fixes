#!/usr/bin/env python3
"""
Fn+F7 半残补丁: _Q18 的 WMI 事件码 0x0288 -> 0x0287.

现象: 未静音时按 F7, EC 走 _Q14 发 0x0287 (huawei-wmi 映射为 KEY_MICMUTE,
      能静音); 已静音时按 F7, EC 走 _Q18 发 0x0288, 驱动没有这个键,
      内核打印 "Unknown key pressed, code: 0x0288" 并丢弃 -> 永远解不了静音。

修法: 把 _Q18 里唯一的那条 Store(0x0288, ^^^^WMI1.WMEN) 的立即数改成
      0x0287。单字节, 表长/偏移/校验和其他设备都不动。

注意: 这是固件层改动, 默认不推荐 —— 优先改驱动 keymap (见
      docs/04-fn-f7-micmute.md)。本工具只做"生成一张可验证的表",
      未经真机启动验证。

用法:
    python3 patch_fn_f7.py dsdt_fixed.aml dsdt_fnfix.aml
    iasl -d dsdt_fnfix.aml && grep -A3 "Method (_Q18" dsdt_fnfix.dsl
"""
import sys

STORE = bytes.fromhex("70 0B 88 02")            # Store(0x0288, ...)
TARGET = bytes.fromhex("5E 5E 5E 5E 2E 57 4D 49 31 57 4D 45 4E")  # ^^^^WMI1.WMEN


def fix_checksum(buf: bytearray) -> None:
    buf[9] = 0
    buf[9] = (-sum(buf)) & 0xFF


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    buf = bytearray(open(src, 'rb').read())

    if buf[:4] != b'DSDT':
        print("错误: 不是 DSDT 表")
        return 1

    hits = []
    i = buf.find(b'_Q18')
    while i >= 0:
        # Method 名后面紧跟 flags(1B) + 包长度, 5..24 字节内必须出现目标 Store
        for off in range(i + 5, i + 25):
            if buf[off:off + 4] == STORE and buf[off + 4:off + 17] == TARGET:
                hits.append(off)
                break
        i = buf.find(b'_Q18', i + 1)

    if len(hits) != 1:
        print("错误: 找到 %d 处匹配 (期望 1 处): %s" % (len(hits), [hex(h) for h in hits]))
        return 1

    off = hits[0]
    buf[off + 2] = 0x87                      # 0x0288 -> 0x0287
    fix_checksum(buf)
    open(dst, 'wb').write(bytes(buf))
    print("命中偏移: 0x%X, 0x88 -> 0x87" % (off + 2))
    print("已写出: %s (%d 字节, 校验和 0x%02X)" % (dst, len(buf), buf[9]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
