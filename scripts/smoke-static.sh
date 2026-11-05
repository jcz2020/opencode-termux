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
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; fail=1; }

echo "==> 解包 $DEB"
dpkg-deb -x "$DEB" "$TMP"
P="$TMP/data/data/com.termux/files/usr"

echo "==> 文件齐全"
for f in bin/opencode bin/opencode.real \
         lib/opencode/libnoheap.so \
         lib/opencode/librust_pty.so \
         lib/opencode/otui/@opentui/core-android-arm64/libopentui.so; do
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
check_wrapper_var OTUI_ASSET_ROOT 'OTUI_ASSET_ROOT=' "$P/lib/opencode/otui"
check_wrapper_var BUN_PTY_LIB   'BUN_PTY_LIB='  "$P/lib/opencode/librust_pty.so"

echo "==> 架构与依赖"
for f in bin/opencode.real lib/opencode/libnoheap.so lib/opencode/librust_pty.so \
         lib/opencode/otui/@opentui/core-android-arm64/libopentui.so; do
  [ -f "$P/$f" ] || continue
  arch="$(file -b "$P/$f")"
  case "$arch" in
    *aarch64*) ;;
    *) bad "$f 架构不对: $arch" ;;
  esac
  glibc="$(readelf -d "$P/$f" 2>/dev/null | grep NEEDED | grep -viE 'libc\.so|libm\.so|libdl\.so|liblog\.so|libstdc\+\+|libc\+\+_shared' || true)"
  if [ -n "$glibc" ]; then bad "$f 有非 bionic 依赖: $glibc"; fi
done
[ "$fail" = 0 ] && ok "全部 ELF 都是 aarch64 且只依赖 bionic"

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
else
  bad "二进制里找不到上游版本号 $expected_ver（可能编成了 dev/占位版本）"
fi

if [ -n "$CORE_DIR" ] && [ -n "$PTY_DIR" ]; then
  echo "==> FFI 符号"
  HERE="$(cd "$(dirname "$0")" && pwd)"
  bash "$HERE/verify-abi.sh" \
    "$P/lib/opencode/otui/@opentui/core-android-arm64/libopentui.so" \
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
