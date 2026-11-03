#!/usr/bin/env bash
# build.sh — spike: 在 x86_64 Linux runner 上把 opentui 编成 aarch64-linux-android 的
# libopentui.so（bionic），用来验证"不依赖 Hope2333"的源码线。
#
# 设计要点：上游 CI 的正常做法是 zig 自己搞定一切（含 libc/libc++）。
# 设备上 zig 会拒绝为 android "provide libc"，所以之前只能产出 .a；
# 这里在 runner 上一次跑通：zig 编核心 + 链接成 .so。
#
# 用法：build.sh <opentui-src> <ndk-sysroot> [api=30]
set -euo pipefail

SRC="${1:?opentui source dir}"
SYSROOT="${2:?NDK sysroot (…/toolchains/llvm/prebuilt/linux-x86_64/sysroot)}"
API="${3:-30}"
NATIVE="$SRC/packages/native"
TARGET="aarch64-linux-android.${API}"

cd "$NATIVE"

echo "==> zig $(zig version) / target $TARGET"
zig version | grep -q '^0\.17\.0$' || { echo "ERROR: 需要 zig 0.17.0（opentui 的 .zig-version）" >&2; exit 1; }

echo "==> 解 vendor 依赖（yoga/ghostty/uucode，无网络）"
sh scripts/prepare-zig-deps.sh

echo "==> 打 build.zig 补丁（只在 zig 自己找不到 sysroot 时生效）"
python3 - "$PWD" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
p = root / "build.zig"
s = p.read_text()
if "spike patch: aarch64-linux-android" in s:
    print("   already patched")
    sys.exit(0)

block = '''
// ── spike patch: aarch64-linux-android via NDK sysroot (-Dsysroot=...) ──
var android_sysroot: ?[]const u8 = null;

const AndroidPaths = struct { inc: []const u8, inc_arch: []const u8 };

fn androidPaths(b: *std.Build) ?AndroidPaths {
    const sys = android_sysroot orelse return null;
    return .{
        .inc = b.pathJoin(&.{ sys, "usr/include" }),
        .inc_arch = b.pathJoin(&.{ sys, "usr/include/aarch64-linux-android" }),
    };
}

fn addAndroidSysrootIncludes(b: *std.Build, step: anytype, target: std.Build.ResolvedTarget) void {
    if (target.result.abi != .android) return;
    const a = androidPaths(b) orelse return;
    step.addSystemIncludePath(.{ .cwd_relative = a.inc });
    step.addSystemIncludePath(.{ .cwd_relative = a.inc_arch });
}

fn addAndroidSysrootModule(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.abi != .android) return;
    const a = androidPaths(b) orelse return;
    module.addSystemIncludePath(.{ .cwd_relative = a.inc });
    module.addSystemIncludePath(.{ .cwd_relative = a.inc_arch });
    module.addCMacro("__ANDROID_API__", "30");
}
'''

anchor = 'const LIB_NAME = "opentui";'
assert anchor in s
s = s.replace(anchor, anchor + "\n" + block, 1)

a = '    const target_option = b.option'
assert a in s
s = s.replace(a, '    android_sysroot = b.option([]const u8, "sysroot", "NDK sysroot for aarch64-linux-android");\n' + a, 1)

for anchor_line, step in (
    ('    miniaudio_translate.addIncludePath(b.path("src"));', 'miniaudio_translate'),
    ('    yoga_translate.addIncludePath(yoga_dep.path(""));', 'yoga_translate'),
):
    assert anchor_line in s
    s = s.replace(anchor_line, anchor_line + f"\n    addAndroidSysrootIncludes(b, {step}, target);", 1)

h = '''    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/opentui.h"),
        .target = target,
        .optimize = optimize,
    });'''
assert h in s
s = s.replace(h, h + "\n    addAndroidSysrootIncludes(b, header, target);", 1)

m = '    applyDependencies(b, module, optimize, target, build_options);'
assert m in s
s = s.replace(m, '    addAndroidSysrootModule(b, module, target);\n' + m, 1)

p.write_text(s)
print("   patched build.zig")
PY

echo "==> zig build（aarch64-linux-android.$API, ReleaseFast）"
zig build --sysroot "$SYSROOT" -Dsysroot="$SYSROOT" \
  -Dlibrary-target="$TARGET" -Doptimize=ReleaseFast

echo "==> 找产物"
OUT="$NATIVE/lib/$TARGET"
ls -la "$OUT" || true
SO="$OUT/libopentui.so"
[ -f "$SO" ] || { echo "ERROR: 没有 libopentui.so（zig 该 target 没出动态库）" >&2; exit 1; }

echo "==> 自检"
file "$SO"
size=$(stat -c%s "$SO")
echo "size: $size bytes"
[ "$size" -gt 5000000 ] || { echo "ERROR: 产物太小，可能没链进去" >&2; exit 1; }

echo "--- 不能有 C++ ABI 未解析符号（__1 / __ndk1 混链的典型症状）"
undef="$(readelf --dyn-syms -W "$SO" | awk '$7=="UND" && $8 ~ /^_Z/ {print $8}' | sort -u)"
if [ -n "$undef" ]; then
  echo "$undef"
  echo "WARN: 仍有 C++ 未解析符号（见上）；TUI 加载时会失败，但产物先带回去分析" >&2
else
  echo "OK: 没有未解析的 C++ ABI 符号"
fi

echo "--- 导出符号数"
echo "$(readelf --dyn-syms -W "$SO" | awk '$7!="UND" && $4=="FUNC" {c++} END{print c+0}')"

echo "DONE: $SO"
