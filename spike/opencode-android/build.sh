#!/usr/bin/env bash
# build.sh — 用官方 android bun 把 opencode 源码编成 aarch64 bionic 二进制。
#
# 用法：build.sh <opencode-src> <libopentui.so> <librust_pty.so> [bun-release=bun-v1.4.4]
#
# 做的事：
#   1. 给 packages/cli/script/build.ts 打 android target 补丁（4 处）
#   2. 给 node_modules/@opentui/core 打 android 资产描述补丁（1 处）
#   3. bun build --compile --target=bun-linux-aarch64-android
set -euo pipefail

SRC="${1:?opencode source dir}"
LIBOPENTUI="${2:?libopentui.so (bionic)}"
LIBPTY="${3:?librust_pty.so (bionic)}"
RELEASE="${4:-bun-v1.4.4}"

cd "$SRC"

echo "==> 1/3 补丁 packages/cli/script/build.ts"
python3 - packages/cli/script/build.ts <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if "android-arm64" in s:
    print("   already patched"); sys.exit(0)

# (a) 目标表加 android
old = """  { os: "win32", arch: "x64", avx2: false },
]"""
new = """  { os: "win32", arch: "x64", avx2: false },
  { os: "android", arch: "arm64" },
]"""
assert old in s, "allTargets anchor"
s = s.replace(old, new, 1)

# (b) bun 资产名：android 走 linux 平台 + android abi（bun-linux-aarch64-android.zip）
old = """  const platform = item.os === "win32" ? "windows" : item.os"""
new = """  const platform = item.os === "win32" ? "windows" : item.os === "android" ? "linux" : item.os"""
assert old in s, "platform anchor"
s = s.replace(old, new, 1)

old = """    item.abi,
    item.avx2 === false ? "baseline" : undefined,
  ]"""
new = """    item.os === "android" ? "android" : item.abi,
    item.avx2 === false ? "baseline" : undefined,
  ]"""
assert old in s, "asset name anchor"
s = s.replace(old, new, 1)

# (c) 编译目标名：bun-android-arm64 不是合法 target，映射成 bun-linux-aarch64-android
old = """      target: target.replace(binary, "bun") as Bun.Build.CompileTarget,"""
new = """      target: compileTarget(item) as Bun.Build.CompileTarget,"""
assert old in s, "compile target anchor"
s = s.replace(old, new, 1)

old = """function targetName(item: (typeof allTargets)[number]) {"""
new = """function compileTarget(item: (typeof allTargets)[number]) {
  // bun 的 android 目标叫 bun-linux-aarch64-android（不是 bun-android-arm64）
  if (item.os === "android") return item.arch === "arm64" ? "bun-linux-aarch64-android" : "bun-linux-x64-android"
  return targetName(item).replace(binary, "bun")
}

function targetName(item: (typeof allTargets)[number]) {"""
assert old in s, "targetName anchor"
s = s.replace(old, new, 1)

# (d) parcel watcher：android 没有预编译 binding，降级成"不可用"
old = """        contents: `export default () => require(${JSON.stringify(parcelWatcherPackage)})`,"""
new = """        contents:
          item.os === "android"
            ? `export default () => { throw new Error("parcel watcher is not available on android") }`
            : `export default () => require(${JSON.stringify(parcelWatcherPackage)})`,"""
assert old in s, "watcher anchor"
s = s.replace(old, new, 1)

p.write_text(s)
print("   patched build.ts")
PY

echo "==> 2/3 补丁 node_modules/@opentui/core（允许 android 资产目标）"
python3 - <<'PY'
import os, pathlib
# bun 1.4 的 isolated 布局把包放在隐藏目录 node_modules/.bun/... 下，glob 抓不到
roots = []
for dirpath, dirnames, _ in os.walk("."):
    if dirpath.endswith(os.path.join("node_modules", "@opentui", "core")):
        roots.append(pathlib.Path(dirpath))
        dirnames[:] = []
        continue
    dirnames[:] = [d for d in dirnames if d not in (".git", "dist", "build", ".turbo")]
if not roots:
    raise SystemExit("找不到 @opentui/core（bun install 没装 / 布局变了）")
print("   roots:", *roots)
files = [q for root in roots for q in root.rglob("*.js") if "NATIVE_FILE_NAMES" in q.read_text(errors="ignore")]
if not files:
    raise SystemExit("找不到 NATIVE_FILE_NAMES（@opentui/core 结构变了？）")
for p in files:
    s = p.read_text()
    changed = False
    if 'android: "libopentui.so"' not in s:
        s = s.replace('win32: "opentui.dll"', 'win32: "opentui.dll",\n  android: "libopentui.so"', 1)
        changed = True
    # 让原生库可以用专用环境变量定位（OPENTUI_NATIVE_LIB）。
    # 不能用 OTUI_ASSET_ROOT：那被 opentui 当作"所有资产"的根，
    # 缺 parser.worker.js / tree-sitter.wasm 就会抛
    # "Missing OpenTUI asset ..."。
    anchor = "async function resolveNativeLibraryPath() {\n  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());"
    if anchor in s and "OPENTUI_NATIVE_LIB" not in s:
        s = s.replace(anchor,
            "async function resolveNativeLibraryPath() {\n"
            "  const explicit = process.env.OPENTUI_NATIVE_LIB;\n"
            "  if (explicit) return explicit;\n"
            "  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());", 1)
        changed = True
    if changed:
        p.write_text(s)
        print("   patched", p)
PY

echo "==> 3/3 bun build --compile --target=bun-linux-aarch64-android"
export BUN_COMPILE_RELEASE="$RELEASE"
export OPENCODE_TARGET=android-arm64
export OTUI_ASSET_ROOT="" # 运行时注入，构建期不需要
cd packages/cli
# 默认构建嵌入 Web UI 资产（供 opencode serve 和 App WebView 消费）
# 若仅需 TUI 快速迭代，可设 SKIP_WEB_UI=1
bun run script/build.ts ${SKIP_WEB_UI:+--skip-web-ui} --skip-install

echo "==> 产物"
OUT="dist/cli-android-arm64"
find "$OUT" -maxdepth 3 -type f | head -10
BIN="$OUT/bin/opencode"
[ -f "$BIN" ] || { echo "ERROR: 没有 $BIN" >&2; exit 1; }
file "$BIN"
echo "size: $(stat -c%s "$BIN") bytes"

echo "==> 记录依赖库（运行时由 wrapper 注入）"
echo "libopentui: $LIBOPENTUI"
echo "librust_pty: $LIBPTY"
sha256sum "$LIBOPENTUI" "$LIBPTY" "$BIN"
