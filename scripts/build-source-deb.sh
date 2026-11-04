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
DEBVER="${VER}+termux${REV}"
BUN_RELEASE="${BUN_RELEASE:-bun-v1.4.4}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/src-$VER"
DIST="$ROOT/dist"
PREFIX_DIR="data/data/com.termux/files/usr"

: "${NDK_ROOT:?NDK_ROOT 未设置}"
NDKBIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
CC_ANDROID="$NDKBIN/aarch64-linux-android${API}-clang"
STRIP="$NDKBIN/llvm-strip"
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
case "$OTUI_VER" in
  0.8.0|0.8.1) echo "   note: 把 opentui 从 $OTUI_VER 提到 0.8.2（zig 0.17 兼容）"; OTUI_VER=0.8.2 ;;
esac
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
  -o "$WORK/libnoheap.so" "$ROOT/src/noheap.c"

echo "==> [4/4] opencode（官方 android bun 编译）"
( cd oc && [ -d node_modules ] || bun install --frozen-lockfile || bun install )
OPENCODE_VERSION="$VER" bash "$ROOT/spike/opencode-android/build.sh" \
  "$WORK/oc" "$LIBOTUI" "$LIBPTY" "$BUN_RELEASE" | tail -6
BIN="$WORK/oc/packages/cli/dist/cli-android-arm64/bin/opencode"
[ -f "$BIN" ] || { echo "ERROR: 没有 $BIN" >&2; exit 1; }

echo "==> strip（二进制 200MB+ → 体积能砍一大截）"
cp "$BIN" "$WORK/opencode.stripped"
"$STRIP" --strip-all "$WORK/opencode.stripped" || echo "   WARN: strip 失败，沿用未 strip 版本"
ls -la "$BIN" "$WORK/opencode.stripped" | awk '{print "   ", $5, $9}'

# ── 3. 组装 rootfs ──────────────────────────────────────────────
echo "==> 组装 deb rootfs"
BUILD="$WORK/debroot"
rm -rf "$BUILD"
mkdir -p "$BUILD/$PREFIX_DIR/bin" \
         "$BUILD/$PREFIX_DIR/lib/opencode/otui/@opentui/core-android-arm64" \
         "$BUILD/DEBIAN"

install -m 755 "$WORK/opencode.stripped" "$BUILD/$PREFIX_DIR/bin/opencode.real"
install -m 755 "$WORK/libnoheap.so"      "$BUILD/$PREFIX_DIR/lib/opencode/libnoheap.so"
install -m 755 "$LIBPTY"                 "$BUILD/$PREFIX_DIR/lib/opencode/librust_pty.so"
install -m 644 "$LIBOTUI"                "$BUILD/$PREFIX_DIR/lib/opencode/otui/@opentui/core-android-arm64/libopentui.so"
install -m 644 "$WORK/otui/packages/native/include/opentui.h" \
  "$BUILD/$PREFIX_DIR/lib/opencode/otui/@opentui/core-android-arm64/opentui.h" 2>/dev/null || true

cat > "$BUILD/$PREFIX_DIR/bin/opencode" <<'WRAP'
#!/data/data/com.termux/files/usr/bin/bash
# opencode-termux wrapper（源码线）
#  * libnoheap.so：关 bionic 堆 tagging，否则 bun/libopentui 报
#    "Pointer exceeds safe integer range"
#  * OTUI_ASSET_ROOT：把 @opentui/core 指到我们自编的 libopentui.so
#  * BUN_PTY_LIB：把 bun-pty 指到我们自编的 librust_pty.so
P="${PREFIX:-/data/data/com.termux/files/usr}"
LD_PRELOAD="$P/lib/opencode/libnoheap.so${LD_PRELOAD:+:$LD_PRELOAD}"
OTUI_ASSET_ROOT="$P/lib/opencode/otui"
BUN_PTY_LIB="$P/lib/opencode/librust_pty.so"
export LD_PRELOAD OTUI_ASSET_ROOT BUN_PTY_LIB
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
          "$BUILD/$PREFIX_DIR/lib/opencode/librust_pty.so"

# ── 4. 打包 + 自检 ──────────────────────────────────────────────
echo "==> dpkg-deb"
DEB="$DIST/opencode_${DEBVER}_aarch64.deb"
dpkg-deb --build --root-owner-group "$BUILD" "$DEB" >/dev/null
sha256sum "$DEB" > "$DEB.sha256"

echo "==> 自检"
dpkg-deb -I "$DEB" | sed -n '1,14p'
echo "--- files"
dpkg-deb -c "$DEB" | awk '{print "   ", $1, $6}'
echo "--- 架构检查（都必须是 aarch64 bionic）"
for f in bin/opencode.real lib/opencode/libnoheap.so lib/opencode/librust_pty.so \
         lib/opencode/otui/@opentui/core-android-arm64/libopentui.so; do
  printf '   %-62s ' "$f"
  dpkg-deb --fsys-tarfile "$DEB" | tar -xO "./data/data/com.termux/files/usr/$f" 2>/dev/null | file - | cut -d: -f2 | cut -c1-60
done
echo "DONE: $DEB"
