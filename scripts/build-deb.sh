#!/data/data/com.termux/files/usr/bin/bash
# build-deb.sh <version> — 用上游 aarch64 二进制打出自己的 deb。
#
# 产物布局（无 dpkg-divert，升级安全）：
#   $PREFIX/bin/opencode                     wrapper（设 LD_PRELOAD 后 exec .real）
#   $PREFIX/bin/opencode.real                真二进制（它的 RUNPATH=$ORIGIN/../lib/opencode，
#                                            所以必须留在 bin/ 下，才能找到 crhandler shim）
#   $PREFIX/lib/opencode/libopencode-crhandler.so   上游自带 SIGSYS/close_range shim
#   $PREFIX/lib/opencode/libnoheap.so               本项目加的「关堆 tagging」shim
#
# 包名沿用 opencode，版本后缀 +termux<N>，这样 dpkg -i 视为升级而不是冲突。
set -euo pipefail

VER="${1:-}"
[ -n "$VER" ] || { echo "usage: build-deb.sh <version>   e.g. build-deb.sh 2.2.5" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/cache"
PKG="$CACHE/opencode-${VER}-1-aarch64.pkg.tar.xz"
REV="${REV:-1}"
DEBVER="${VER}+mirror${REV}"
PREFIX_DIR="data/data/com.termux/files/usr"
BUILD="$ROOT/build/root"
OUT="$ROOT/dist"

[ -f "$PKG" ] || { echo "ERROR: 缺 $PKG，先跑 scripts/fetch.sh $VER" >&2; exit 1; }

echo "==> 解包上游包"
rm -rf "$ROOT/build"
mkdir -p "$BUILD"
tar -xf "$PKG" -C "$ROOT/build/src" 2>/dev/null || { mkdir -p "$ROOT/build/src"; tar -xf "$PKG" -C "$ROOT/build/src"; }
UP="$ROOT/build/src/$PREFIX_DIR"

echo "==> 编译 libnoheap.so"
# CC 可覆盖：本机用 Termux clang；CI 里用 NDK 的 aarch64-linux-android<api>-clang。
CC="${CC:-clang}"
command -v "$CC" >/dev/null || { echo "ERROR: 找不到编译器 $CC" >&2; exit 1; }
echo "    CC=$CC"
mkdir -p "$ROOT/build/shim"
"$CC" -shared -fPIC -O2 -o "$ROOT/build/shim/libnoheap.so" "$ROOT/src/noheap.c"

echo "==> 组装 rootfs"
mkdir -p "$BUILD/$PREFIX_DIR/bin" "$BUILD/$PREFIX_DIR/lib/opencode" "$BUILD/DEBIAN"
install -m 755 "$UP/bin/opencode"                          "$BUILD/$PREFIX_DIR/bin/opencode.real"
install -m 644 "$UP/lib/opencode/libopencode-crhandler.so" "$BUILD/$PREFIX_DIR/lib/opencode/libopencode-crhandler.so"
install -m 755 "$ROOT/build/shim/libnoheap.so"             "$BUILD/$PREFIX_DIR/lib/opencode/libnoheap.so"

cat > "$BUILD/$PREFIX_DIR/bin/opencode" <<'WRAP'
#!/system/bin/sh
# opencode-termux wrapper（支持 prefix 自推导重定位）
# 注入 libnoheap.so 关 bionic 堆 tagging，
# 否则 Android 11+ 上 bun / libopentui 抛 "Pointer exceeds safe integer range"。
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

export PREFIX="$P"
export LD_PRELOAD="$P/lib/opencode/libnoheap.so${LD_PRELOAD:+:$LD_PRELOAD}"
exec "$P/bin/opencode.real" "$@"
WRAP
chmod 755 "$BUILD/$PREFIX_DIR/bin/opencode"

cat > "$BUILD/DEBIAN/control" <<CTL
Package: opencode
Version: $DEBVER
Architecture: aarch64
Maintainer: $(git config user.name 2>/dev/null || echo local) <$(git config user.email 2>/dev/null || echo local@localhost)>
Section: utils
Priority: optional
Depends: bash, clang
Conflicts: opencode-wrapper
Replaces: opencode1-wrapper-standalone
Installed-Size: $(( $(du -sk "$BUILD" | cut -f1) - 0 ))
Description: OpenCode for Termux (mirror repack of upstream $VER + heap-tagging shim)
 Repackaged native Termux build of OpenCode ($VER) with a small LD_PRELOAD
 shim that disables bionic heap pointer tagging, required for the TUI on
 Android 11+ (bun/libopentui: "Pointer exceeds safe integer range").
CTL

cat > "$BUILD/DEBIAN/postinst" <<'POST'
#!/data/data/com.termux/files/usr/bin/bash
set -e
echo "opencode installed: $(/data/data/com.termux/files/usr/bin/opencode --version 2>/dev/null || echo '(run opencode --version)')"
exit 0
POST
chmod 755 "$BUILD/DEBIAN/postinst"

echo "==> 修目录权限（Termux umask 077 → dpkg-deb 要求 0755+）"
find "$BUILD" -type d -exec chmod 755 {} +
find "$BUILD" -type f -exec chmod 644 {} +
chmod 755 "$BUILD/DEBIAN/postinst" \
          "$BUILD/$PREFIX_DIR/bin/opencode" \
          "$BUILD/$PREFIX_DIR/bin/opencode.real" \
          "$BUILD/$PREFIX_DIR/lib/opencode/libnoheap.so"

echo "==> 打包"
mkdir -p "$OUT"
DEB="$OUT/opencode_${DEBVER}_aarch64.deb"
dpkg-deb --build --root-owner-group "$BUILD" "$DEB" >/dev/null

echo "==> 自检"
dpkg-deb -I "$DEB" | sed -n '1,12p'
echo "    files:"
dpkg-deb -c "$DEB" | awk '{print "      " $6}' | grep -v '/$'
printf '%s  %s\n' "$(sha256sum "$DEB" | cut -d' ' -f1)" "$DEB" > "$DEB.sha256"
echo "==> $DEB"

echo "==> 制作独立运行时 bundle"
bash "$ROOT/scripts/build-runtime-bundle.sh" "$DEB" "$VER" "mirror$REV"
