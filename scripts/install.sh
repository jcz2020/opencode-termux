#!/data/data/com.termux/files/usr/bin/bash
# install.sh [deb] — 装本项目产出的 deb；自动清掉旧的手工 dpkg-divert 安装方式。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN="$PREFIX/bin/opencode"
REAL="$BIN.real"
DEB="${1:-$(ls -1t "$ROOT"/dist/opencode_*_aarch64.deb 2>/dev/null | head -1)}"

[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "ERROR: 找不到 deb，先 make deb" >&2; exit 1; }

# 迁移：从「dpkg-divert + 手写 wrapper」切回「包自带 wrapper」
if dpkg-divert --list "$BIN" 2>/dev/null | grep -q "diversion of $BIN"; then
  echo "==> 发现旧的手工 diversion，先还原"
  rm -f "$BIN"
  dpkg-divert --local --remove --rename --divert "$REAL" "$BIN"
fi

echo "==> dpkg -i $DEB"
dpkg -i "$DEB"

# dpkg 不会因为"文件被手工改过"而报错（那是 dpkg-divert 的活儿），
# 但我们 wrapper + .real 的形态必须保持一致：真二进制在 opencode.real，
# wrapper 在 opencode。若被别的安装方式覆盖过，这里修回来。
if [ ! -x "$BIN" ] || ! grep -q 'opencode.real' "$BIN" 2>/dev/null; then
  echo "==> 修复 wrapper（dpkg 装的包应自带 opencode wrapper）"
  if [ -f "$REAL" ]; then
    cat > "$BIN" <<'WRAP'
#!/system/bin/sh
# opencode-termux wrapper
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
    fi
    ;;
esac

export PREFIX="$P"
export LD_PRELOAD="$P/lib/opencode/libnoheap.so${LD_PRELOAD:+:$LD_PRELOAD}"
[ -f "$P/lib/opencode/libopentui.so" ] && export OPENTUI_NATIVE_LIB="$P/lib/opencode/libopentui.so"
[ -f "$P/lib/opencode/librust_pty.so" ] && export BUN_PTY_LIB="$P/lib/opencode/librust_pty.so"
exec "$P/bin/opencode.real" "$@"
WRAP
    chmod 755 "$BIN"
  fi
fi

echo "==> 校验"
dpkg -l opencode | tail -1
opencode --version
command -v oc >/dev/null && printf 'oc        -> %s\n' "$(oc --version)"

# 源码线的包会带自编的原生库；镜像线没有。两种都要能起来。
if [ -f "$PREFIX/lib/opencode/librust_pty.so" ]; then
  echo "    （源码线：自带 librust_pty.so + otui/libopentui.so）"
else
  echo "    （镜像线：用上游 bionic 二进制）"
fi
