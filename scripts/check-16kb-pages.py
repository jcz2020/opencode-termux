#!/usr/bin/env python3
"""check-16kb-pages.py — 校验 ELF 的所有 PT_LOAD 是否满足 16 KB 页对齐。

Android 15/16 在 16 KB 页设备上要求可执行文件与共享库的每个 PT_LOAD
段的 p_align >= 0x4000。4 KB 对齐（0x1000）的 .so 会直接加载失败。

用法:
    python3 scripts/check-16kb-pages.py FILE [FILE ...]

任一文件不满足时退出码为 1；非 ELF / 没有 PT_LOAD 也按失败处理。
"""
import struct
import sys

MIN_ALIGN = 0x4000
PT_LOAD = 1


def load_alignments(path):
    """返回 [(index, p_offset, p_vaddr, p_align), ...]。"""
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 16 or data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")

    ei_class, ei_data = data[4], data[5]
    if ei_data == 1:
        endian = "<"
    elif ei_data == 2:
        endian = ">"
    else:
        raise ValueError("bad EI_DATA=%d" % ei_data)

    if ei_class == 2:  # ELF64
        # e_ident[16] + e_type/e_machine/e_version/e_entry/e_phoff/e_shoff/
        # e_flags/e_ehsize/e_phentsize/e_phnum/...
        (_type, _machine, _version, _entry, phoff, _shoff, _flags,
         _ehsize, phentsize, phnum, _shentsize, _shnum, _shstrndx) = \
            struct.unpack_from(endian + "HHIQQQIHHHHHH", data, 16)
        phfmt = endian + "IIQQQQQQ"
        off_idx, vaddr_idx = 2, 3
    elif ei_class == 1:  # ELF32
        (_type, _machine, _version, _entry, phoff, _shoff, _flags,
         _ehsize, phentsize, phnum, _shentsize, _shnum, _shstrndx) = \
            struct.unpack_from(endian + "HHIIIIIHHHHHH", data, 16)
        phfmt = endian + "IIIIIIII"
        off_idx, vaddr_idx = 1, 2
    else:
        raise ValueError("bad EI_CLASS=%d" % ei_class)

    expected = struct.calcsize(phfmt)
    if phentsize < expected:
        raise ValueError("bad e_phentsize=%d" % phentsize)
    if phoff + phentsize * phnum > len(data):
        raise ValueError("program header table out of bounds")

    loads = []
    for i in range(phnum):
        ph = struct.unpack_from(phfmt, data, phoff + i * phentsize)
        if ph[0] != PT_LOAD:
            continue
        loads.append((i, ph[off_idx], ph[vaddr_idx], ph[7]))
    return loads


def main(argv):
    if len(argv) < 2:
        print("usage: check-16kb-pages.py FILE [FILE ...]", file=sys.stderr)
        return 2

    failed = False
    for path in argv[1:]:
        print("== %s" % path)
        try:
            loads = load_alignments(path)
        except (OSError, ValueError, struct.error) as exc:
            print("  FAIL 无法解析 ELF: %s" % exc)
            failed = True
            continue

        if not loads:
            print("  FAIL 没有 PT_LOAD 段")
            failed = True
            continue

        for index, offset, vaddr, align in loads:
            status = "OK" if align >= MIN_ALIGN else "FAIL"
            print("  [%s] LOAD[%d] offset=0x%x vaddr=0x%x p_align=0x%x"
                  % (status, index, offset, vaddr, align))
            if align < MIN_ALIGN:
                failed = True

    if failed:
        print("\nFAIL: 存在 p_align < 0x4000 的 PT_LOAD（Android 15/16 16 KB 页不兼容）",
              file=sys.stderr)
        return 1

    print("\nOK: 所有 PT_LOAD 均 >= 0x4000（16 KB）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
