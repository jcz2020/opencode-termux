#!/usr/bin/env bash
# build-runtime-bundle.sh [deb-or-dir] [version] [rev]
#
# 制作符合 docs/RUNTIME-CONTRACT.md 规范的独立运行时 bundle（tar.zst）与 manifest。
# 可消费已有的 .deb 包或构建阶段的 rootfs 目录。
#
# rev 可以是数字（按源码线拼成 +termux<N>），也可以直接传
# termux<N> / mirror<N>（镜像线必须这样传，否则 manifest 的 tag 会错）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
mkdir -p "$DIST"

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
  INPUT="$(ls -1t "$DIST"/opencode_*_aarch64.deb 2>/dev/null | head -1 || true)"
fi

[ -n "$INPUT" ] && [ -e "$INPUT" ] || {
  echo "ERROR: 未找到输入文件/目录。用法: $0 [deb-or-dir] [version] [rev]" >&2
  exit 1
}

VERSION="${2:-}"
REV="${3:-}"

# 若未显式传入版本，尝试从文件名解析（如 opencode_2.2.5+termux1_aarch64.deb）
if [ -z "$VERSION" ] || [ -z "$REV" ]; then
  fname="$(basename "$INPUT")"
  if [[ "$fname" =~ opencode_([0-9.]+)\+(termux|mirror)([0-9]+)_aarch64\.deb ]]; then
    VERSION="${BASH_REMATCH[1]}"
    tag_prefix="${BASH_REMATCH[2]}"
    REV="${BASH_REMATCH[3]}"
    TAG_VER="${VERSION}+${tag_prefix}${REV}"
  else
    VERSION="${VERSION:-2.2.5}"
    REV="${REV:-1}"
    TAG_VER="${VERSION}+termux${REV}"
  fi
else
  # 显式传入 version/rev：兼容「数字 = 源码线」与「termuxN/mirrorN」两种写法。
  # 镜像线 build-deb.sh 传的是 mirror<N>，不能一律加 +termux。
  if [[ "$REV" =~ ^(termux|mirror)[0-9]+$ ]]; then
    TAG_VER="${VERSION}+${REV}"
  elif [[ "$REV" =~ ^[0-9]+$ ]]; then
    TAG_VER="${VERSION}+termux${REV}"
  else
    echo "ERROR: rev 必须形如 2、termux2 或 mirror2，收到: $REV" >&2
    exit 1
  fi
fi

TMP="$(mktemp -d "/data/data/com.termux/files/usr/tmp/runtime-bundle.XXXXXX" 2>/dev/null || mktemp -d "/tmp/runtime-bundle.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE/usr/bin" "$STAGE/usr/lib/opencode" "$STAGE/usr/licenses"

echo "==> 准备运行时内容（来自 $INPUT）"
if [ -f "$INPUT" ]; then
  # 是 deb 包：解包提取文件
  dpkg-deb -x "$INPUT" "$TMP/unpack"
  USR_SRC="$(find "$TMP/unpack" -type d -path '*/files/usr' | head -1)"
  if [ -z "$USR_SRC" ]; then
    USR_SRC="$(find "$TMP/unpack" -type d -name 'usr' | head -1)"
  fi
  [ -n "$USR_SRC" ] && [ -d "$USR_SRC" ] || { echo "ERROR: deb 内未找到 usr 目录" >&2; exit 1; }
elif [ -d "$INPUT" ]; then
  if [ -d "$INPUT/bin" ] && [ -d "$INPUT/lib" ]; then
    USR_SRC="$INPUT"
  else
    USR_SRC="$(find "$INPUT" -type d -path '*/files/usr' | head -1 || true)"
    if [ -z "$USR_SRC" ]; then
      USR_SRC="$(find "$INPUT" -type d -name 'usr' | head -1 || true)"
    fi
  fi
  [ -n "$USR_SRC" ] && [ -d "$USR_SRC" ] || { echo "ERROR: 输入目录中未找到 usr 结构" >&2; exit 1; }
fi

# 拷贝二进制与库
cp "$USR_SRC/bin/opencode.real" "$STAGE/usr/bin/opencode.real"
cp -a "$USR_SRC/lib/opencode/"* "$STAGE/usr/lib/opencode/"

# Android 15/16 的 16 KB 页设备要求 PT_LOAD 的 p_align >= 0x4000。
# 在打包前统一验一遍，任何输入（新 deb / 旧 deb / 目录）都不能漏掉。
echo "==> 16 KB 页对齐检查（Android 15/16）"
ELF_CHECK=("$STAGE/usr/bin/opencode.real")
for so in "$STAGE"/usr/lib/opencode/*.so; do
  [ -e "$so" ] && ELF_CHECK+=("$so")
done
python3 "$ROOT/scripts/check-16kb-pages.py" "${ELF_CHECK[@]}"

# 注入自推导 prefix 的 relocatable wrapper
cat > "$STAGE/usr/bin/opencode" <<'WRAP'
#!/system/bin/sh
# opencode wrapper: auto-detect prefix, set runtime environment, exec binary.
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

# 双重保障启动：若直接 exec 遇到权限限制，尝试通过 system linker 启动
if [ -x "/system/bin/linker64" ] && [ -f "$P/bin/opencode.real" ]; then
  exec /system/bin/linker64 "$P/bin/opencode.real" "$@"
else
  exec "$P/bin/opencode.real" "$@"
fi
WRAP
chmod 755 "$STAGE/usr/bin/opencode" "$STAGE/usr/bin/opencode.real"

# 附带许可声明文件
[ -f "$ROOT/NOTICE" ] && cp "$ROOT/NOTICE" "$STAGE/usr/NOTICE"
[ -f "$ROOT/LICENSE" ] && cp "$ROOT/LICENSE" "$STAGE/usr/licenses/LICENSE"

# 权限规整
find "$STAGE" -type d -exec chmod 755 {} +
chmod 755 "$STAGE/usr/lib/opencode"/*.so 2>/dev/null || true

OUT_NAME="runtime-${TAG_VER}-aarch64.tar.zst"
OUT_TAR="$DIST/$OUT_NAME"

echo "==> 打包 $OUT_NAME"
# 优先用 -19 压制以节省体积
tar -cf - -C "$STAGE" usr | zstd -19 -T0 -f -o "$OUT_TAR"

SHA="$(sha256sum "$OUT_TAR" | awk '{print $1}')"
SIZE="$(stat -c%s "$OUT_TAR")"
echo "$SHA  $OUT_NAME" > "$OUT_TAR.sha256"

REPO="${GITHUB_REPOSITORY:-jcz2020/opencode-termux}"
MANIFEST="$DIST/runtime-manifest.json"

cat > "$MANIFEST" <<JSON
{
  "schema": 1,
  "channel": "stable",
  "version": "${TAG_VER}",
  "abi": "aarch64",
  "format": "tar.zst",
  "minAppVersion": 1,
  "sha256": "${SHA}",
  "size": ${SIZE},
  "url": "https://github.com/${REPO}/releases/download/v${TAG_VER}/${OUT_NAME}",
  "notes": "OpenCode Android runtime bundle"
}
JSON

echo "==> 产出清单"
echo "  bundle:   $OUT_TAR ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} B"))"
echo "  sha256:   $SHA"
echo "  manifest: $MANIFEST"
