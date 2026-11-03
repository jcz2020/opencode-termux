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

echo "==> 校验"
dpkg -l opencode | tail -1
opencode --version
command -v oc >/dev/null && printf 'oc        -> %s\n' "$(oc --version)"
