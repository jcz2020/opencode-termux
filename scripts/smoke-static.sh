#!/usr/bin/env bash
# smoke-static.sh — 无设备冒烟：解开 deb 做静态体检。
#
# CI 里没有 Android 设备，但绝大多数问题都能在静态层面抓到：
#   * wrapper 里指向的三个库/目录是否都在包里
#   * ELF 架构对不对（必须是 aarch64）
#   * 有没有混进 glibc 依赖
#   * libopentui / librust_pty 的 FFI 符号是否齐全（scripts/verify-abi.sh）
#   * 二进制里能不能找到版本字符串
#
# 用法：smoke-static.sh <deb> [<@opentui/core 目录> <bun-pty 目录>]
set -euo pipefail

DEB="${1:?用法: smoke-static.sh <deb>}"
CORE_DIR="${2:-}"
PTY_DIR="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }

echo "==> 解包 $DEB"
dpkg-deb -x "$DEB" "$TMP"
P="$TMP/data/data/com.termux/files/usr"

echo "==> 文件齐全"
# 两种包布局：
#   源码线 → 自带 libopentui.so / librust_pty.so
#   重打包线 → 只有上游二进制 + libnoheap.so
REQUIRED="bin/opencode bin/opencode.real lib/opencode/libnoheap.so lib/opencode/opencode-updater.sh"
if [ -f "$P/lib/opencode/libopentui.so" ]; then
  SOURCE_LINE=1
  REQUIRED="$REQUIRED lib/opencode/librust_pty.so lib/opencode/libopentui.so"
else
  SOURCE_LINE=0
  echo "  --   这是重打包线布局（无自编原生库），跳过原生库检查"
fi
for f in $REQUIRED; do
  if [ -f "$P/$f" ]; then ok "$f"; else bad "$f 缺失"; fi
done

echo "==> wrapper 指向的路径都存在"
wrapper="$(cat "$P/bin/opencode")"
check_wrapper_var() {
  local var="$1" pattern="$2" target="$3"
  if printf '%s' "$wrapper" | grep -q "$pattern"; then
    if [ -e "$target" ]; then ok "$var → ${target#$TMP/}"
    else bad "$var → ${target#$TMP/} 不存在"; fi
  else
    echo "  --   $var 未在 wrapper 里出现（跳过）"
  fi
}
check_wrapper_var LD_PRELOAD    'LD_PRELOAD='   "$P/lib/opencode/libnoheap.so"
[ "$SOURCE_LINE" = 1 ] && {
  check_wrapper_var OPENTUI_NATIVE_LIB 'OPENTUI_NATIVE_LIB=' "$P/lib/opencode/libopentui.so"
  check_wrapper_var BUN_PTY_LIB   'BUN_PTY_LIB='  "$P/lib/opencode/librust_pty.so"
}

echo "==> 架构与依赖"
for f in bin/opencode.real lib/opencode/libnoheap.so lib/opencode/librust_pty.so \
         lib/opencode/libopentui.so; do
  [ -f "$P/$f" ] || continue
  [ -f "$P/$f" ] || continue
  arch="$(file -b "$P/$f")"
  case "$arch" in
    *aarch64*) ;;
    *) bad "$f 架构不对: $arch" ;;
  esac
  glibc="$(readelf -d "$P/$f" 2>/dev/null | grep NEEDED | grep -viE 'libc\.so|libm\.so|libdl\.so|liblog\.so|libstdc\+\+|libc\+\+_shared|libopencode-crhandler' || true)"
  if [ -n "$glibc" ]; then bad "$f 有非 bionic 依赖: $glibc"; fi
done
[ "$fail" = 0 ] && ok "全部 ELF 都是 aarch64 且只依赖 bionic"

echo "==> 16 KB 页对齐（Android 15/16）"
ELF_CHECK=("$P/bin/opencode.real")
for so in "$P"/lib/opencode/*.so; do
  [ -e "$so" ] && ELF_CHECK+=("$so")
done
if python3 "$HERE/check-16kb-pages.py" "${ELF_CHECK[@]}"; then
  ok "所有 PT_LOAD 的 p_align 均 >= 0x4000"
else
  bad "存在 p_align < 0x4000 的 PT_LOAD"
fi

echo "==> 版本字符串"
# 版本号被 bun 以 define 形式编进去，表现为裸的 "x.y.z" 字符串。
# 注意：不要用 `strings | grep -q`（grep -q 提前退出会让 strings 收到 SIGPIPE，
# 在 set -o pipefail 下整条管道会被判为失败）——先落盘再匹配。
strings -a "$P/bin/opencode.real" > "$TMP/strings.txt" 2>/dev/null || true
# 上游版本号（deb 版本去掉 +termux<N>）必须出现在二进制里 —— 说明编译时
# 真的把 OPENCODE_VERSION 编进去了，而不是只打了个 dev 分支的占位版本。
expected_ver="$(dpkg-deb -f "$DEB" Version | sed -E 's/\+termux[0-9]+$//')"
if grep -qxF "$expected_ver" "$TMP/strings.txt"; then
  ok "二进制里含上游版本号 $expected_ver"
elif [ "$SOURCE_LINE" = 1 ]; then
  # 源码线：版本是 OPENCODE_VERSION define 进去的，必须精确匹配
  bad "二进制里找不到上游版本号 $expected_ver（可能编成了 dev/占位版本）"
else
  ok "（重打包线不校验内嵌版本号）"
fi

if [ "$SOURCE_LINE" = 1 ] && [ -n "$CORE_DIR" ] && [ -n "$PTY_DIR" ]; then
  echo "==> FFI 符号"
  bash "$HERE/verify-abi.sh" \
    "$P/lib/opencode/libopentui.so" \
    "$P/lib/opencode/librust_pty.so" "$CORE_DIR" "$PTY_DIR" || fail=1
fi

echo "==> dpkg 元数据"
pkgver="$(dpkg-deb -f "$DEB" Version)"
pkgname="$(dpkg-deb -f "$DEB" Package)"
arch="$(dpkg-deb -f "$DEB" Architecture)"
echo "  $pkgname $pkgver ($arch)"
case "$pkgver" in *+termux*) ok "版本带 termux 后缀" ;; *) bad "版本没有 termux 后缀" ;; esac
[ "$arch" = aarch64 ] && ok "架构 aarch64" || bad "架构 $arch"

[ "$fail" = 0 ] || { echo "=== 静态冒烟失败 ==="; exit 1; }
echo "=== 静态冒烟通过 ==="
