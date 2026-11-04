#!/usr/bin/env python3
"""abi-symbols.py — 提取 @opentui/core 声明要 dlopen 的符号名（每行一个）。

只取 `var nativeSymbols = { ... }` 对象里的键；宽泛的 grep 会把注释和字符串里
出现的 ot_xxx 也算进来，导致误报。
"""
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: abi-symbols.py <@opentui/core dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    names: set[str] = set()
    for f in root.rglob("*.js"):
        try:
            s = f.read_text(errors="ignore")
        except OSError:
            continue
        for m in re.finditer(r"var nativeSymbols = \{(.*?)\n\};", s, re.S):
            names |= set(re.findall(r"^\s{2}([A-Za-z_][A-Za-z0-9_]*): \{", m.group(1), re.M))
    print("\n".join(sorted(names)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
