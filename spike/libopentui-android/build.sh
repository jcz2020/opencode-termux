#!/usr/bin/env bash
# build.sh — 在 x86_64 Linux runner 上把 opentui 编成 aarch64-linux-android（bionic）的
# libopentui.so。这是"不依赖上游打包"的源码线第一块砖。
#
# 为什么要在 runner 上做：zig 0.17.0 不会为 android "provide libc"
# （`unable to provide libc for target …-android.30`），所以 .so 不能由 zig 直接链。
# runner 是 x86_64，可以直接跑 NDK 自带的 clang —— 于是分工：
#
#   Zig 部分（opentui 核心 + C 依赖） → zig build → libopentui.a（不链接，不涉及 libc++）
#   C++ 部分（yoga / yoga-bridge）     → NDK clang++（天然 std::__ndk1）
#   合并                              → NDK clang++ -shared -static-libstdc++ → libopentui.so
#
# 用法：build.sh <opentui-src> <ndk-root> [api=30]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$REPO_ROOT}"
SRC="${1:?opentui source dir}"
NDK="${2:?NDK root (…/android-ndk-r27c)}"
API="${3:-30}"
# Android 15/16 的 16 KB 页设备要求所有 PT_LOAD 的 p_align >= 0x4000。
# NDK r27 及更早版本默认仍是 4 KB 对齐，必须显式传给链接器（r28+ 默认 16 KB）。
PAGE_LDFLAGS=(-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384)
SYSROOT="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
HOSTBIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CXX="$HOSTBIN/aarch64-linux-android${API}-clang++"
NATIVE="$SRC/packages/native"
TARGET="aarch64-linux-android.${API}"
LIBS="$SYSROOT/usr/lib/aarch64-linux-android/$API"

[ -x "$CXX" ] || { echo "ERROR: 没有 $CXX" >&2; exit 1; }
cd "$NATIVE"

echo "==> zig $(zig version) / cxx $("$CXX" --version | head -1) / target $TARGET"

echo "==> NDK 补 libpthread/librt 软链（Android 已并入 libc）"
for l in libpthread.so librt.so; do [ -e "$LIBS/$l" ] || ln -sf libc.so "$LIBS/$l"; done

echo "==> 解 vendor 依赖（yoga/ghostty/uucode，无网络）"
sh scripts/prepare-zig-deps.sh

export ZIG_MM="$(zig version | cut -d. -f1-2)"
echo "==> 打 build.zig 补丁：android 下 C++ 交给 NDK clang"
python3 - "$PWD" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
p = root / "build.zig"
s = p.read_text()

# zig 0.17 把 Optimize 的成员从 ReleaseFast/ReleaseSafe/ReleaseSmall/Debug
# 改成了 fast/safe/small/debug。只有 0.17+ 才需要归一化。
import os
zigmm = os.environ.get("ZIG_MM", "")
use_new = False
if zigmm:
    try:
        major, minor = (int(x) for x in zigmm.split(".")[:2])
        use_new = (major, minor) >= (0, 17)
    except ValueError:
        use_new = False
if use_new:
    for old, new in ((".ReleaseFast", ".fast"), (".ReleaseSafe", ".safe"),
                     (".ReleaseSmall", ".small"), (".Debug", ".debug")):
        if old in s:
            s = s.replace(old, new)
            print("   normalized", old, "->", new)
if "spike patch: aarch64-linux-android" in s:
    print("   already patched"); sys.exit(0)

block = '''
// ── spike patch: aarch64-linux-android ──
// NDK sysroot 头文件路径（zig 自己找不到），以及"android 的 C++ 交给 NDK clang"开关。
var android_sysroot: ?[]const u8 = null;

fn addAndroidSysrootIncludes(b: *std.Build, step: anytype, target: std.Build.ResolvedTarget) void {
    if (target.result.abi != .android) return;
    const sys = android_sysroot orelse return;
    step.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sys, "usr/include" }) });
    step.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sys, "usr/include/aarch64-linux-android" }) });
}

fn addAndroidSysrootModule(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.abi != .android) return;
    const sys = android_sysroot orelse return;
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sys, "usr/include" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sys, "usr/include/aarch64-linux-android" }) });
    module.addCMacro("__ANDROID_API__", "30");
    // 只产静态库：libc/libc++ 的链接交给 build.sh 里的 NDK clang++
    module.link_libc = false;
}
'''

anchor = 'const LIB_NAME = "opentui";'
assert anchor in s
s = s.replace(anchor, anchor + "\n" + block, 1)

a = '    const target_option = b.option'
assert a in s
s = s.replace(a, '    android_sysroot = b.option([]const u8, "sysroot", "NDK sysroot for aarch64-linux-android");\n' + a, 1)

for line, step in (
    ('    miniaudio_translate.addIncludePath(b.path("src"));', 'miniaudio_translate'),
    ('    yoga_translate.addIncludePath(yoga_dep.path(""));', 'yoga_translate'),
):
    assert line in s
    s = s.replace(line, line + f"\n    addAndroidSysrootIncludes(b, {step}, target);", 1)

h = '''    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/opentui.h"),
        .target = target,
        .optimize = optimize,
    });'''
assert h in s
s = s.replace(h, h + "\n    addAndroidSysrootIncludes(b, header, target);", 1)

# android 不要 -ldl/-lpthread/-lm（由 NDK clang++ 链接）
old_linux = '''        .linux => {
            module.linkSystemLibrary("dl", .{});
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("m", .{});
        },'''
new_linux = '''        .linux => {
            if (target.result.abi != .android) {
                module.linkSystemLibrary("dl", .{});
                module.linkSystemLibrary("pthread", .{});
                module.linkSystemLibrary("m", .{});
            }
        },'''
assert old_linux in s
s = s.replace(old_linux, new_linux, 1)

m = '    applyDependencies(b, module, optimize, target, build_options);'
assert m in s
s = s.replace(m, '    addAndroidSysrootModule(b, module, target);\n' + m, 1)

# android：不编 C++（由 build.sh 用 NDK clang++ 编）
old = '''    module.link_libcpp = true;
    module.addIncludePath(yoga_dep.path(""));
    module.addCSourceFiles(.{
        .root = yoga_dep.path(""),
        .files = &YOGA_CXX_SOURCES,
        .flags = flags,
    });
    module.addCSourceFile(.{ .file = b.path("src/yoga-bridge.cpp"), .flags = flags });'''
new = '''    module.addIncludePath(yoga_dep.path(""));
    if (!android_cxx_external) {
        module.link_libcpp = true;
        module.addCSourceFiles(.{
            .root = yoga_dep.path(""),
            .files = &YOGA_CXX_SOURCES,
            .flags = flags,
        });
        module.addCSourceFile(.{ .file = b.path("src/yoga-bridge.cpp"), .flags = flags });
    }'''
assert old in s
s = s.replace(old, new, 1)

assert 'var android_sysroot: ?[]const u8 = null;' in s
s = s.replace('var android_sysroot: ?[]const u8 = null;',
              'var android_sysroot: ?[]const u8 = null;\nvar android_api: u32 = 30;\nvar android_cxx_external = false;', 1)
assert 'var android_api: u32 = 30;' in s

opt = '    android_sysroot = b.option([]const u8, "sysroot", "NDK sysroot for aarch64-linux-android");'
assert opt in s
s = s.replace(opt, opt + '\n    android_cxx_external = b.option(bool, "android-cxx-external", "C++ objects come from the NDK clang") orelse false;'
              + '\n    android_api = @intCast(b.option(u32, "android-api", "Android API level (default 30)") orelse 30);', 1)

p.write_text(s)
print("   patched build.zig")
PY

echo "==> 1/3 zig 编核心 → libopentui.a"
zig build --sysroot "$SYSROOT" -Dsysroot="$SYSROOT" -Dandroid-api="$API" \
  -Dandroid-cxx-external=true -Dlibrary-target="$TARGET" -Doptimize=ReleaseFast || true
A="$NATIVE/lib/$TARGET/libopentui.a"
[ -f "$A" ] || { echo "ERROR: 没产出 $A" >&2; exit 1; }
echo "    $A ($(stat -c%s "$A") bytes)"

echo "==> 2/3 NDK clang++ 编 C++（yoga + yoga-bridge，std::__ndk1）"
OBJ="$NATIVE/.spike-obj"; rm -rf "$OBJ"; mkdir -p "$OBJ"
CXXFLAGS=(-target "aarch64-linux-android$API" -std=c++20 -fexceptions -frtti -fPIC -O2
          -I zig-deps/yoga -I "$SYSROOT/usr/include" -I "$SYSROOT/usr/include/aarch64-linux-android")
n=0
for f in $(sed -n 's/^ *"\(yoga\/[^"]*\.cpp\)",$/\1/p' build.zig); do
  "$CXX" "${CXXFLAGS[@]}" -c "zig-deps/yoga/$f" -o "$OBJ/$(echo "$f" | tr '/' '_').o"
  n=$((n+1))
done
"$CXX" "${CXXFLAGS[@]}" -c src/yoga-bridge.cpp -o "$OBJ/yoga-bridge.o"
n=$((n+1))
# bionic 缺的 glibc 扩展（pthread_tryjoin_np 等）——必须按 C 编（否则名字会被 mangle）
"$HOSTBIN/aarch64-linux-android${API}-clang" -target "aarch64-linux-android$API" -O2 -fPIC \
  -c "$GITHUB_WORKSPACE/spike/libopentui-android/compat.c" -o "$OBJ/compat.o"
n=$((n+1))
echo "    $n 个 C++ 目标文件"

echo "==> 3/3 链接 libopentui.so"
OUT="$NATIVE/lib/$TARGET/libopentui.so"
"$CXX" -target "aarch64-linux-android$API" -shared -fPIC -o "$OUT" \
  "${PAGE_LDFLAGS[@]}" \
  -Wl,--whole-archive "$A" -Wl,--no-whole-archive "$OBJ"/*.o \
  -Wl,-soname,libopentui.so -static-libstdc++ -static-libgcc -lm -ldl

echo "==> 自检"
file "$OUT"
echo "size: $(stat -c%s "$OUT") bytes"
[ "$(stat -c%s "$OUT")" -gt 5000000 ] || { echo "ERROR: 产物太小" >&2; exit 1; }
python3 "$REPO_ROOT/scripts/check-16kb-pages.py" "$OUT"

undef="$(readelf --dyn-syms -W "$OUT" | awk '$7=="UND" && $8 ~ /^_Z/ {print $8}' | sort -u)"
if [ -n "$undef" ]; then
  echo "WARN: 仍有 C++ 未解析符号："; echo "$undef"
else
  echo "OK: 没有未解析的 C++ ABI 符号"
fi
echo "兼容层符号: $(readelf --dyn-syms -W "$OUT" | awk '$8=="pthread_tryjoin_np" {print "OK"}' | head -1)"
echo "导出的 FUNC 数: $(readelf --dyn-syms -W "$OUT" | awk '$7!="UND" && $4=="FUNC" {c++} END{print c+0}')"
echo "DONE: $OUT"
