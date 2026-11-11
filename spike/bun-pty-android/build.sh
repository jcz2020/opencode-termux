#!/usr/bin/env bash
# build.sh — 交叉编 bun-pty 的 Rust cdylib（librust_pty.so）到 aarch64-linux-android。
#
# 用法：build.sh <bun-pty 源码目录> <NDK 根目录> [api=30]
#
# 唯一需要打补丁的地方：portable-pty → serial → termios 0.2.2 没有 android 的 cfg，
# bionic 的 termios 与 linux 一致，所以把 linux 分支复制给 android（并清掉该 crate
# 的 per-file 校验和）。
set -euo pipefail

SRC="${1:?bun-pty source dir}"
NDK="${2:?NDK root}"
API="${3:-30}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOSTBIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CLANG="$HOSTBIN/aarch64-linux-android${API}-clang"

[ -x "$CLANG" ] || { echo "ERROR: 没有 $CLANG" >&2; exit 1; }
cd "$SRC/rust-pty"

echo "==> vendor 依赖"
mkdir -p .cargo
cargo vendor vendor > .cargo/config.toml

echo "==> 给 termios 补 android cfg"
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("vendor/termios/src/os/mod.rs")
s = p.read_text()
if 'target_os = "android"' not in s:
    s = s.replace('#[cfg(target_os = "linux")] pub use self::linux as target;',
                  '#[cfg(any(target_os = "linux", target_os = "android"))] pub use self::linux as target;')
    s = s.replace('#[cfg(target_os = "linux")] pub mod linux;',
                  '#[cfg(any(target_os = "linux", target_os = "android"))] pub mod linux;')
    p.write_text(s)
    print("   patched", p)
else:
    print("   already patched")
# vendored 目录改了内容，必须清掉 per-file 校验和
ck = p.parents[2] / ".cargo-checksum.json"
d = json.loads(ck.read_text()); d["files"] = {}; ck.write_text(json.dumps(d))
PY

echo "==> cargo build (aarch64-linux-android)"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export CC_aarch64_linux_android="$CLANG"
export AR_aarch64_linux_android="$HOSTBIN/llvm-ar"
# Android 15/16 的 16 KB 页设备要求 PT_LOAD 的 p_align >= 0x4000。
# NDK r27 的 clang 默认按 4 KB 链接，必须通过 rustc 把参数透传给链接器。
PAGE_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$PAGE_RUSTFLAGS"
cargo build --release --target aarch64-linux-android --offline

SO="target/aarch64-linux-android/release/librust_pty.so"
[ -f "$SO" ] || { echo "ERROR: 没产出 $SO" >&2; exit 1; }
file "$SO"
echo "size: $(stat -c%s "$SO") bytes"
python3 "$REPO_ROOT/scripts/check-16kb-pages.py" "$SO"
echo "--- NEEDED"
readelf -d "$SO" | grep -E 'NEEDED|SONAME' || true
echo "DONE: $SRC/rust-pty/$SO"
