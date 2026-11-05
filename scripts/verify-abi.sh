#!/usr/bin/env bash
# verify-abi.sh — 校验原生库与 JS 侧的 FFI 契约是否匹配。
#
# 背景：`@opentui/core`（JS）与 `libopentui.so`（原生）必须**同版本**，否则
# FFI 结构体布局对不上，运行时才炸：
#   NativeError: ot_session_get_renderer_state failed: InvalidArgument
# 这个错在设备上很难定位，所以打 deb 之前在 CI 里静态比对符号表。
#
# 用法：verify-abi.sh <libopentui.so> <librust_pty.so> <@opentui/core 包目录> <bun-pty 包目录>
set -euo pipefail

OTUI_SO="${1:?libopentui.so}"
PTY_SO="${2:?librust_pty.so}"
CORE_DIR="${3:?@opentui/core 包目录}"
PTY_DIR="${4:?bun-pty 包目录}"

fail=0

echo "==> libopentui.so 导出符号"
otui_exported="$(readelf --dyn-syms -W "$OTUI_SO" | awk '$7 != "UND" && $8 ~ /^[A-Za-z_]/ {print $8}' | sort -u)"
echo "    $(printf '%s\n' "$otui_exported" | grep -c .) 个"

# @opentui/core 里声明要 dlopen 的符号：精确取 nativeSymbols 对象的键。
# （不能用宽泛的 grep —— 那会把注释/字符串里的 ot_xxx 也算进来。）
echo "==> @opentui/core 需要的符号"
HERE="$(cd "$(dirname "$0")" && pwd)"
core_expected="$(python3 "$HERE/abi-symbols.py" "$CORE_DIR")"
n_core="$(printf '%s\n' "$core_expected" | grep -c .)"
echo "    $n_core 个"

missing_core="$(comm -23 <(printf '%s\n' "$core_expected") <(printf '%s\n' "$otui_exported"))"
if [ -n "$missing_core" ]; then
  echo "ERROR: libopentui.so 缺少这些符号（JS 与原生库版本不匹配？）:"
  printf '    %s\n' $missing_core | head -30
  fail=1
else
  echo "OK: @opentui/core 需要的符号全部存在"
fi

echo "==> bun-pty 需要的符号"
pty_expected="$(grep -ohE '\bbun_pty_[a-z_]+' -r "$PTY_DIR" --include='*.ts' --include='*.js' | sort -u)"
pty_exported="$(readelf --dyn-syms -W "$PTY_SO" | awk '$7 != "UND" && $8 ~ /^bun_pty_/ {print $8}' | sort -u)"
n_pty="$(printf '%s\n' "$pty_expected" | grep -c .)"
echo "    需要 $n_pty 个，导出 $(printf '%s\n' "$pty_exported" | grep -c .) 个"

missing_pty="$(comm -23 <(printf '%s\n' "$pty_expected") <(printf '%s\n' "$pty_exported"))"
if [ -n "$missing_pty" ]; then
  echo "ERROR: librust_pty.so 缺少:"; printf '    %s\n' $missing_pty; fail=1
else
  echo "OK: bun-pty 符号齐全"
fi

echo "==> 动态依赖检查（不能有 glibc）"
for so in "$OTUI_SO" "$PTY_SO"; do
  bad="$(readelf -d "$so" | grep NEEDED | grep -viE 'libc\.so|libm\.so|libdl\.so|liblog\.so|libstdc\+\+|libc\+\+_shared' || true)"
  if [ -n "$bad" ]; then
    echo "ERROR: $(basename "$so") 有非 bionic 依赖:"; echo "$bad"; fail=1
  else
    echo "OK: $(basename "$so") 只依赖 bionic"
  fi
done

[ "$fail" = 0 ] || { echo "=== ABI 校验失败 ==="; exit 1; }
echo "=== ABI 校验通过 ==="
