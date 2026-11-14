#!/usr/bin/env bash
# build.sh — 从源码构建 aarch64 的 opencode-pty（process-daemon）。
#
# 为什么不用 npm 预编译包：上游 0.5.2 的 pipe 子进程退出后故意保留僵尸，
# 只有显式 terminate 才 reap；opencode 侧只在 25 条历史溢出时 eviction，
# 于是长会话稳定残留 25 个 Z。修复（安全 reap）必须改 process-daemon，
# 所以这里从同一个 opencode tag 的源码构建。
#
# 用法：build.sh <packages/process-daemon 源码目录> <输出文件>
#
# 依赖：
#   * rustup + rust-toolchain.toml（crate 要求 1.90）
#   * zig 0.16.x（ghostty 的 build.zig 要求 >= 0.16；**不能**用 opentui 的 0.17）
#   * cargo-zigbuild
#   * git（build.rs 会浅拉 ghostty 的固定 revision）
#
# 环境变量：
#   ZIG=<zig 0.16 可执行文件>      默认 PATH 里的 zig
#   OPTPTY_FROM_SOURCE=0            由上层决定是否调用本脚本
#   OPTPTY_SKIP_TESTS=1             跳过 host 单测（快速迭代用）
#   TARGET=...                      默认 aarch64-unknown-linux-musl
#   STRIP=...                       strip 工具（默认 llvm-strip 或 strip）
set -euo pipefail

SRC="${1:?usage: build.sh <process-daemon-src> <output>}"
OUT="${2:?usage: build.sh <process-daemon-src> <output>}"
TARGET="${TARGET:-aarch64-unknown-linux-musl}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

[ -f "$SRC/Cargo.toml" ] || { echo "ERROR: $SRC 不是 process-daemon 源码目录" >&2; exit 1; }
grep -q '^name = "opencode-pty"' "$SRC/Cargo.toml" || { echo "ERROR: 包名不是 opencode-pty" >&2; exit 1; }

# ghostty 的 build.zig 直接调 `zig`，cargo-zigbuild 也从 PATH 找，所以统一前置。
if [ -n "${ZIG:-}" ]; then
  [ -x "$ZIG" ] || { echo "ERROR: ZIG=$ZIG 不可执行" >&2; exit 1; }
  echo "==> zig: $("$ZIG" version) ($ZIG)"
  case "$("$ZIG" version)" in
    0.16.*) ;;
    *) echo "ERROR: ghostty 需要 zig 0.16.x，当前是 $("$ZIG" version)。" >&2
       echo "       opentui 用的 0.17 不能拿来编 ghostty；请用 ZIG= 单独指定。" >&2
       exit 1 ;;
  esac
  export PATH="$(dirname "$ZIG"):$PATH"
else
  echo "==> zig: $(zig version 2>/dev/null || echo missing)"
  case "$(zig version 2>/dev/null || true)" in
    0.16.*) ;;
    *) echo "ERROR: 需要 zig 0.16.x（可用 ZIG=<path> 指定）" >&2; exit 1 ;;
  esac
fi

echo "==> 补丁：pipe 僵尸安全回收"
python3 "$HERE/patch-reap.py" "$SRC"

if [ "${OPTPTY_SKIP_TESTS:-0}" != "1" ]; then
  echo "==> host 单测（验证 reap 判据）"
  ( cd "$SRC" && cargo test --quiet )
fi

echo "==> 确保 rust target: $TARGET"
( cd "$SRC" && rustup target add "$TARGET" >/dev/null 2>&1 || true )

# Android 15/16 的 16 KB 页要求；对静态 musl 也显式钉住，避免链接器默认漂移。
export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
# ghostty 的 release 构建同样钉 baseline CPU，避免按构建机 CPU 生成指令。
export OPENCODE_ZIG_CPU="${OPENCODE_ZIG_CPU:-baseline}"

echo "==> cargo zigbuild --release --target $TARGET"
( cd "$SRC" && cargo zigbuild --release --target "$TARGET" )

BIN="$SRC/target/$TARGET/release/opencode-pty"
[ -f "$BIN" ] || { echo "ERROR: 没有产物 $BIN" >&2; exit 1; }

echo "==> strip"
mkdir -p "$(dirname "$OUT")"
cp "$BIN" "$OUT"
STRIP_BIN="${STRIP:-$(command -v llvm-strip || command -v strip || true)}"
if [ -n "$STRIP_BIN" ]; then
  "$STRIP_BIN" --strip-all "$OUT" || echo "   WARN: strip 失败，沿用未 strip 版本"
else
  echo "   WARN: 找不到 strip，跳过"
fi
chmod 755 "$OUT"

echo "==> 产物检查"
file "$OUT"
case "$(file -b "$OUT")" in
  *aarch64*) ;;
  *) echo "ERROR: 不是 aarch64 产物" >&2; exit 1 ;;
esac
case "$(file -b "$OUT")" in
  *"statically linked"*) ;;
  *) echo "ERROR: 不是静态链接；Android 上缺 musl 运行时会无法启动" >&2; exit 1 ;;
esac
if command -v readelf >/dev/null 2>&1; then
  if readelf -d "$OUT" 2>/dev/null | grep -q NEEDED; then
    echo "ERROR: 静态产物不应有 DT_NEEDED" >&2
    readelf -d "$OUT" | grep NEEDED >&2
    exit 1
  fi
fi
python3 "$ROOT/scripts/check-16kb-pages.py" "$OUT"

# 版本字符串（crate version）必须以明文编进去，方便和 opencode-pty.lock 对账。
ver="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$SRC/Cargo.toml" | head -1)"
strings -a "$OUT" > "$OUT.strings"
if grep -qxF "$ver" "$OUT.strings"; then
  echo "   OK: 二进制含版本号 $ver"
else
  echo "   WARN: 二进制里没找到裸版本号 $ver（打包仍会继续）"
fi
rm -f "$OUT.strings"

echo "==> opencode-pty 源码构建完成: $OUT ($(stat -c%s "$OUT") bytes)"
