#!/usr/bin/env python3
"""
Honor MagicBook Pro 14 (FMB-P / Core Ultra 5 225H) 原厂 DSDT 二进制修补器.

根因: Device(NFC0) 内模块级语句
         CreateWordField (SBGF, 0x17, INT1)
         INT1 = GNUM (0x0014080A)
      GNUM()->GINF() 对方法返回的 Package 副本再 Index()，ACPICA 抛
      AE_AML_INTERNAL，导致整张 DSDT 加载失败 (Namespace 只剩 9 个对象)。
      Windows 忽略模块级 AML 错误，所以只有 Linux 中招。

修法: 把这条 Store 指令的 14 字节改成 14 个 Noop(0xA3)，长度/偏移/设备路径
      全部不变，然后 OEM Revision +1 并重算校验和。

用法:
    # 1) 取原厂表
    sudo cat /sys/firmware/acpi/tables/DSDT > dsdt_stock.aml
    # 2) 打补丁
    python3 patch_dsdt.py dsdt_stock.aml dsdt_fixed.aml
    # 3) 校验 (可选, 需要 acpica)
    acpiexec -b quit dsdt_fixed.aml | grep "Namespace contains"
    #    期望 5765 objects, 故障时只有 9
"""
import sys

PATTERN = bytes.fromhex("70 47 4E 55 4D 0C 0A 08 14 00 49 4E 54 31")  # Store(GNUM(0x0014080A), INT1)
NOOP    = bytes([0xA3] * 14)


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
    start = 0
    while True:
        i = buf.find(PATTERN, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1

    if len(hits) != 1:
        print("错误: 找到 %d 处匹配 (期望 1 处): %s" % (len(hits), [hex(h) for h in hits]))
        return 1

    off = hits[0]
    print("命中偏移: 0x%X" % off)
    buf[off:off + len(PATTERN)] = NOOP

    # OEM Revision (表头 0x18, 4 字节小端) +1
    rev = int.from_bytes(buf[0x18:0x1C], 'little')
    buf[0x18:0x1C] = (rev + 1).to_bytes(4, 'little')
    print("OEM Revision: %d -> %d" % (rev, rev + 1))

    fix_checksum(buf)
    open(dst, 'wb').write(bytes(buf))
    print("已写出: %s (%d 字节, 校验和 0x%02X)" % (dst, len(buf), buf[9]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
