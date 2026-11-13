#!/usr/bin/env bash
# build-source-deb.sh — 纯源码线：从上游 opencode 源码出一条 Termux deb。
#
# 不取任何上游打包产物；四个件全部现编：
#   libopentui.so      zig 核心 + NDK clang++ 编 yoga，静态链 libc++
#   librust_pty.so     cargo + NDK clang 交叉编（bun-pty）
#   opencode.real      官方 android bun 编译 opencode 源码
#   libnoheap.so       我们的 6KB shim（关 bionic 堆 tagging）
#
# 用法：build-source-deb.sh <version> [rev=1]
# 需要环境：NDK_ROOT、zig（0.17.0）、bun、cargo、curl、dpkg-deb
set -euo pipefail

VER="${1:?usage: build-source-deb.sh <version> [rev]}"
REV="${2:-1}"
API="${API:-30}"
DEBVER="${VER}+termux${REV}"   # 源码线仍是 +termux<N>（对外的主线）
BUN_RELEASE="${BUN_RELEASE:-bun-v1.4.4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/src-$VER"
DIST="$ROOT/dist"
PREFIX_DIR="data/data/com.termux/files/usr"

: "${NDK_ROOT:?NDK_ROOT 未设置}"
NDKBIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC_ANDROID="$NDKBIN/aarch64-linux-android${API}-clang"
STRIP="$NDKBIN/llvm-strip"
# NDK r27 默认 4 KB 页对齐；Android 15/16 的 16 KB 页设备要求 PT_LOAD
# 的 p_align >= 0x4000。三个原生件的构建脚本各自加同样的链接参数，这里
# 用于 libnoheap.so。
PAGE_LDFLAGS=(-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384)
[ -x "$CC_ANDROID" ] || { echo "ERROR: 没有 $CC_ANDROID" >&2; exit 1; }

mkdir -p "$WORK" "$DIST"
cd "$WORK"

echo "=============================================================="
echo " opencode $DEBVER  ←  纯源码构建"
echo "=============================================================="

# ── 1. 取源码 ───────────────────────────────────────────────────
if [ ! -d oc/packages/cli ]; then
  echo "==> 取 opencode 源码 v$VER"
  curl -sSL -o oc.tar.gz "https://codeload.github.com/anomalyco/opencode/tar.gz/v$VER" \
    || curl -sSL -o oc.tar.gz "https://codeload.github.com/anomalyco/opencode/tar.gz/$VER"
  mkdir -p oc && tar -xf oc.tar.gz -C oc --strip-components=1
fi

# 原生库版本从 opencode 源码自己的 catalog 里读，保证配套
OTUI_VER=$(python3 -c "
import json;d=json.load(open('oc/package.json'))
c=(d.get('workspaces') or {}).get('catalog') or {}
print(c.get('@opentui/core','0.8.1'))")
# opencode 可能钉 0.8.0/0.8.1，但那两个 tag 的 build.zig 还在用 zig 0.16 的 API
# （b.args / b.build_root，0.17 已删除）。0.8.2 起才迁到 0.17，所以最低钉 0.8.2。
# 公开 FFI（opentui.h）在 0.8.x 内是兼容的，编完在设备上跑一遍 TUI 即可验证。
OTUI_VER="${OTUI_VER_OVERRIDE:-$OTUI_VER}"
BUMP_OTUI=0
case "$OTUI_VER" in
  0.8.0|0.8.1)
    echo "   note: opentui 从 $OTUI_VER 提到 0.8.2（zig 0.17 兼容；原生库与 JS 必须同版本，否则 FFI 结构体不匹配）"
    OTUI_VER=0.8.2; BUMP_OTUI=1 ;;
esac

if [ "$BUMP_OTUI" = "1" ]; then
  echo "==> 同步 opencode catalog 里的 @opentui/* -> $OTUI_VER"
  _tmp=$(mktemp)
  jq --arg v "$OTUI_VER" '.workspaces.catalog |= with_entries(if (.key|startswith("@opentui/")) then .value=$v else . end)' \
    oc/package.json > "$_tmp" && mv "$_tmp" oc/package.json
fi
PTY_VER=$(python3 -c "
import json;d=json.load(open('oc/packages/core/package.json'))
print(d.get('dependencies',{}).get('bun-pty','0.4.11'))")
echo "==> 配套版本：open tui=$OTUI_VER  bun-pty=$PTY_VER"

if [ ! -d otui/packages/native ]; then
  echo "==> 取 opentui 源码 v$OTUI_VER"
  curl -sSL -o otui.tar.gz "https://codeload.github.com/anomalyco/opentui/tar.gz/refs/tags/v$OTUI_VER" \
    || curl -sSL -o otui.tar.gz "https://codeload.github.com/anomalyco/opentui/tar.gz/$OTUI_VER"
  mkdir -p otui && tar -xf otui.tar.gz -C otui --strip-components=1
fi

if [ ! -d bp/rust-pty ]; then
  echo "==> 取 bun-pty 源码 v$PTY_VER"
  curl -sSL -o bp.tar.gz "https://codeload.github.com/sursaone/bun-pty/tar.gz/refs/tags/v$PTY_VER" \
    || curl -sSL -o bp.tar.gz "https://codeload.github.com/sursaone/bun-pty/tar.gz/$PTY_VER"
  mkdir -p bp && tar -xf bp.tar.gz -C bp --strip-components=1
fi

# ── 2. 编三个原生件 ─────────────────────────────────────────────
# opentui 的 .zig-version 必须和我们的 zig 一致（0.17.0）。
# 上游哪天把 @opentui/core 提到需要 zig 0.18 的版本，这里会明确报错，
# 而不是让 zig 吐一堆看不懂的编译错误。
if [ -f "$WORK/otui/.zig-version" ]; then
  need_zig="$(cat "$WORK/otui/.zig-version" | tr -d '[:space:]')"
  have_zig="$(zig version 2>/dev/null || echo unknown)"
  echo "==> zig 版本检查：需要 $need_zig，当前 $have_zig"
  if [ "$need_zig" != "$have_zig" ]; then
    echo "ERROR: opentui v$OTUI_VER 需要 zig $need_zig，本机是 $have_zig。" >&2
    echo "       装对应版本的 zig 后重试；或临时用 OTUI_VER_OVERRIDE 指定一个" >&2
    echo "       与本机 zig 兼容的 opentui 版本。" >&2
    exit 1
  fi
fi

echo "==> [1/4] libopentui.so"
bash "$ROOT/spike/libopentui-android/build.sh" "$WORK/otui" "$NDK_ROOT" "$API" | tail -5
LIBOTUI="$WORK/otui/packages/native/lib/aarch64-linux-android.$API/libopentui.so"
[ -f "$LIBOTUI" ] || { echo "ERROR: 没有 $LIBOTUI" >&2; exit 1; }

echo "==> [2/4] librust_pty.so"
bash "$ROOT/spike/bun-pty-android/build.sh" "$WORK/bp" "$NDK_ROOT" "$API" | tail -4
LIBPTY="$WORK/bp/rust-pty/target/aarch64-linux-android/release/librust_pty.so"
[ -f "$LIBPTY" ] || { echo "ERROR: 没有 $LIBPTY" >&2; exit 1; }

echo "==> [3/4] libnoheap.so"
"$CC_ANDROID" -target "aarch64-linux-android$API" -O2 -fPIC -shared \
  "${PAGE_LDFLAGS[@]}" -o "$WORK/libnoheap.so" "$ROOT/src/noheap.c"

echo "==> [4/4] opencode（官方 android bun 编译）"
if [ "$BUMP_OTUI" = "1" ]; then
  # catalog 改了，bun.lock 的 hash 对不上 → 重装并让 bun 更新 lockfile
  ( cd oc && rm -f bun.lock && bun install )
else
  ( cd oc && [ -d node_modules ] || bun install --frozen-lockfile || bun install )
fi
OPENCODE_VERSION="$VER" bash "$ROOT/spike/opencode-android/build.sh" \
  "$WORK/oc" "$LIBOTUI" "$LIBPTY" "$BUN_RELEASE" | tail -6
BIN="$WORK/oc/packages/cli/dist/cli-android-arm64/bin/opencode"
[ -f "$BIN" ] || { echo "ERROR: 没有 $BIN" >&2; exit 1; }

echo "==> ABI 校验（JS 与原生库符号必须对齐）"
CORE_DIR=$(find "$WORK/oc" -type d -path '*/node_modules/@opentui/core' | head -1)
PTY_DIR=$(find "$WORK/oc" -type d -path '*/node_modules/bun-pty' | head -1)
[ -n "$CORE_DIR" ] || { echo "ERROR: 找不到 @opentui/core" >&2; exit 1; }
[ -n "$PTY_DIR" ] || { echo "ERROR: 找不到 bun-pty" >&2; exit 1; }
bash "$ROOT/scripts/verify-abi.sh" "$LIBOTUI" "$LIBPTY" "$CORE_DIR" "$PTY_DIR"

echo "==> strip（二进制 200MB+ → 体积能砍一大截）"
cp "$BIN" "$WORK/opencode.stripped"
"$STRIP" --strip-all "$WORK/opencode.stripped" || echo "   WARN: strip 失败，沿用未 strip 版本"
ls -la "$BIN" "$WORK/opencode.stripped" | awk '{print "   ", $5, $9}'

echo "==> 16 KB 页对齐检查（Android 15/16）"
python3 "$ROOT/scripts/check-16kb-pages.py" \
  "$LIBOTUI" "$LIBPTY" "$WORK/libnoheap.so" "$WORK/opencode.stripped"

# ── 3. 组装 rootfs ──────────────────────────────────────────────
echo "==> 组装 deb rootfs"
BUILD="$WORK/debroot"
rm -rf "$BUILD"
mkdir -p "$BUILD/$PREFIX_DIR/bin" \
         "$BUILD/$PREFIX_DIR/lib/opencode" \
         "$BUILD/DEBIAN"

install -m 755 "$WORK/opencode.stripped" "$BUILD/$PREFIX_DIR/bin/opencode.real"
install -m 755 "$WORK/libnoheap.so"      "$BUILD/$PREFIX_DIR/lib/opencode/libnoheap.so"
install -m 755 "$LIBPTY"                 "$BUILD/$PREFIX_DIR/lib/opencode/librust_pty.so"
install -m 644 "$LIBOTUI"                "$BUILD/$PREFIX_DIR/lib/opencode/libopentui.so"
install -m 644 "$WORK/otui/packages/native/include/opentui.h" \
  "$BUILD/$PREFIX_DIR/lib/opencode/opentui.h" 2>/dev/null || true
install -m 755 "$ROOT/scripts/install-termux.sh" \
  "$BUILD/$PREFIX_DIR/lib/opencode/opencode-updater.sh"

cat > "$BUILD/$PREFIX_DIR/bin/opencode" <<'WRAP'
#!/system/bin/sh
# opencode-termux wrapper（源码线，支持 prefix 自推导重定位）
#  * libnoheap.so：关 bionic 堆 tagging，否则 bun/libopentui 报
#    "Pointer exceeds safe integer range"
#  * OPENTUI_NATIVE_LIB：把 @opentui/core 的原生库指到我们自编的 libopentui.so
#  * BUN_PTY_LIB：把 bun-pty 指到我们自编的 librust_pty.so
#  * 拦截 update/upgrade：直接调用 Termux 专用更新器，防止被官方脚本覆盖
set -e

SELF="$0"
if command -v realpath >/dev/null 2>&1; then
  SELF="$(realpath "$SELF" 2>/dev/null || echo "$SELF")"
else
  while [ -L "$SELF" ]; do
    _DIR="$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P)"
    _TARGET="$(readlink "$SELF")"
    case "$_TARGET" in
      /*) SELF="$_TARGET" ;;
      *) SELF="$_DIR/$_TARGET" ;;
    esac
  done
fi

_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd -P)"
_DERIVED_PREFIX="$(CDPATH= cd -- "$_BIN_DIR/.." && pwd -P)"

if [ -f "$_DERIVED_PREFIX/lib/opencode/libnoheap.so" ]; then
  P="$_DERIVED_PREFIX"
else
  P="${PREFIX:-$_DERIVED_PREFIX}"
fi

case "${1:-}" in
  update|upgrade)
    shift
    if [ -f "$P/lib/opencode/opencode-updater.sh" ]; then
      exec /data/data/com.termux/files/usr/bin/bash "$P/lib/opencode/opencode-updater.sh" "$@"
    elif [ -f "$P/../scripts/install-termux.sh" ]; then
      exec /data/data/com.termux/files/usr/bin/bash "$P/../scripts/install-termux.sh" "$@"
    else
      echo "ERROR: 未找到更新脚本 $P/lib/opencode/opencode-updater.sh" >&2
      exit 1
    fi
    ;;
esac

export PREFIX="$P"
export LD_PRELOAD="$P/lib/opencode/libnoheap.so${LD_PRELOAD:+:$LD_PRELOAD}"
export OPENTUI_NATIVE_LIB="$P/lib/opencode/libopentui.so"
export BUN_PTY_LIB="$P/lib/opencode/librust_pty.so"

# 2.3.0 起 TUI 会用 process.execPath 重新拉起 `serve --service`。
# 不能经过 /system/bin/linker64：Bun 会把 process.execPath 报成 linker64，
# 子进程命令变成 `linker64 serve --service`，报 expected absolute path 后退出。
# Termux prefix 本身可执行，直接 exec 才能让 Bun 拿到正确的 opencode.real 路径。
exec "$P/bin/opencode.real" "$@"
WRAP
chmod 755 "$BUILD/$PREFIX_DIR/bin/opencode"

installed=$(du -sk "$BUILD" | cut -f1)
cat > "$BUILD/DEBIAN/control" <<CTL
Package: opencode
Version: $DEBVER
Architecture: aarch64
Maintainer: $(git config user.name 2>/dev/null || echo local) <$(git config user.email 2>/dev/null || echo local@localhost)>
Section: utils
Priority: optional
Depends: bash
Conflicts: opencode-wrapper
Replaces: opencode1-wrapper-standalone
Installed-Size: $installed
Description: OpenCode for Termux (built from source, bionic)
 Built entirely from upstream opencode $VER source with the official Android Bun:
 opencode itself, libopentui.so and bun-pty's librust_pty.so are all compiled
 for aarch64-linux-android (bionic) in CI. No glibc, no prebuilt third-party
 Termux packaging. Includes a tiny shim that disables bionic heap pointer
 tagging, which the TUI needs on Android 11+.
CTL

cat > "$BUILD/DEBIAN/postinst" <<'POST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "opencode installed: $(/data/data/com.termux/files/usr/bin/opencode --version 2>/dev/null || echo '(run opencode --version)')"
exit 0
POST
chmod 755 "$BUILD/DEBIAN/postinst"

# Termux umask 077 → dpkg-deb 要求 control 目录 ≥0755
find "$BUILD" -type d -exec chmod 755 {} +
find "$BUILD" -type f -exec chmod 644 {} +
chmod 755 "$BUILD/DEBIAN/postinst" "$BUILD/$PREFIX_DIR/bin/opencode" \
          "$BUILD/$PREFIX_DIR/bin/opencode.real" \
          "$BUILD/$PREFIX_DIR/lib/opencode/libnoheap.so" \
          "$BUILD/$PREFIX_DIR/lib/opencode/librust_pty.so" \
          "$BUILD/$PREFIX_DIR/lib/opencode/opencode-updater.sh"

# ── 4. 打包 + 自检 ──────────────────────────────────────────────
echo "==> dpkg-deb"
DEB="$DIST/opencode_${DEBVER}_aarch64.deb"
dpkg-deb --build --root-owner-group "$BUILD" "$DEB" >/dev/null
# 校验文件用相对文件名，方便用户直接 `sha256sum -c`（不能写 CI 绝对路径）
( cd "$DIST" && sha256sum "$(basename "$DEB")" > "$(basename "$DEB").sha256" )

echo "==> 自检"
dpkg-deb -I "$DEB" | sed -n '1,14p'
echo "--- files"
dpkg-deb -c "$DEB" | awk '{print "   ", $1, $6}'
echo "--- 架构检查（都必须是 aarch64 bionic）"
TMPX="$(mktemp -d)"
dpkg-deb -x "$DEB" "$TMPX"
for f in bin/opencode.real lib/opencode/libnoheap.so lib/opencode/librust_pty.so \
         lib/opencode/libopentui.so; do
  printf '   %-42s ' "$f"
  file -b "$TMPX/data/data/com.termux/files/usr/$f" | cut -c1-58
done
rm -rf "$TMPX"
echo "DONE: $DEB"

echo "==> 制作独立运行时 bundle"
bash "$ROOT/scripts/build-runtime-bundle.sh" "$DEB" "$VER" "$REV"
