# Spike: 不依赖 Hope2333（Android bun + 源码编译 opencode）

日期：2026-11-03/04 · 机器：Termux / Android 16 (API 36) / aarch64 / 15 GB RAM
结论：**方向可行，bun 不再是门槛；只差 bionic 版 `libopentui.so` 的 C++ 运行时链接。**

## 1. bun：官方就有 Android 构建（关键发现）

oven-sh/bun 的 release 里正式发 `bun-linux-aarch64-android.zip`（1.4.4，48.9 MB），
npm 上也有 `@oven/bun-linux-aarch64-android`。本机实测：

```
$ bun --version                      → 1.4.4
$ bun -e 'console.log(process.platform, process.arch)'
android arm64
$ bun build --compile --target=bun-linux-aarch64-android hello.ts
$ ./hello-android                    → hi: bun 1.4.4 on android/arm64
   file: ELF aarch64, interp /system/bin/linker64, Android 28
```

**不需要自己编 bun**（Hope2333 的 `builtins/android-bun` 也是这条路）。

## 2. opencode 源码侧：只差一个 target

上游 `packages/cli/script/build.ts`：

- `allTargets` 只有 linux/darwin/win32 → 需加 `{ os: "android", arch: "arm64" }`。
- `compileExecutable()` 支持 `BUN_COMPILE_RELEASE` 从 bun release 下对应二进制
  （资产名拼法是 `bun-{platform}-{arch}-{abi}`，android 要平台写 `linux`、abi 写 `android`，
  即 `bun-linux-aarch64-android`）。
- `compile.target = targetName().replace("opencode","bun")` → android 需要手动映射成
  `bun-linux-aarch64-android`。
- 依赖两个原生包：`@opentui/core`（Zig）与 `@opencode/pty`。npm 上都没 android 变体。

## 3. @opencode/pty：可以整块跳过

`@opencode/pty-linux-arm64-gnu` 里是 **Rust 写的 sidecar 可执行文件**（3 MB，glibc）。
`packages/cli/script/opencode-pty.ts` 对非 darwin/linux/win32 返回 `undefined`，
即 android 构建里"持久 PTY"功能关闭，构建继续进行——不影响 TUI 主路径。

## 4. libopentui：Zig 静态库已经能为 android 编出来 ✅

- opentui 是 Zig 项目，`.zig-version = 0.17.0`；**Termux 的 `pkg install zig` 正好 0.17.0**。
- `packages/native/build.zig` 的 `-Dlibrary-target` 走 `std.Target.Query.parse`，
  **接受任意 target 字符串**（有 Custom target 分支），不是白名单。
- Zig 的 android 判断是 `os_tag = .linux` + `abi = .android`（`std.Target.Os.Tag` 里没有 `.android`！）。
- Termux 的 NDK 头部（`ndk-sysroot 30`）不能直接用于 cross：bionic 的 `sys/cdefs.h`
  会报 `Unversioned target triples are not supported!`。必须用官方 NDK 的 sysroot。
- 需要的补丁（已在 spike 副本验证）：在 translate-c / C++ 编译阶段注入
  `-isystem <ndk>/usr/include`、`-isystem <ndk>/usr/include/aarch64-linux-android`、
  `-D__ANDROID_API__=30`；**不要**加 `-L`（zig 会把 `--sysroot` 再拼一次）。
- 结果：`lib/aarch64-linux-android.30/libopentui.a`（37 MB）**编译成功**。
- 再把它链成 .so（zig 拒绝为非 gnu/musl 提供 libc，所以走 `-nostdlib` + NDK stub）：

```sh
NDK=~/tmp/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64
SYS=$NDK/sysroot; D=$SYS/usr/lib/aarch64-linux-android/30; L=$SYS/usr/lib/aarch64-linux-android
zig cc -target aarch64-linux-android.30 -shared -nostdlib \
  -o libopentui.so -Wl,--whole-archive libopentui.a -Wl,--no-whole-archive \
  $L/libc++_shared.so $D/libc.so $D/libm.so $D/libdl.so \
  -Wl,-rpath,'$ORIGIN' -Wl,-soname,libopentui.so
```

→ 得到 21.9 MB 的 `libopentui.so`（aarch64 bionic，2090 个导出符号）。

## 5. 当前唯一卡点：C++ 运行时的 namespace 不匹配

用 android bun 的 FFI `dlopen` 这份 .so：

```
dlopen failed: cannot locate symbol "_ZTISt12out_of_range"
  → (补 libc++abi 后) "_ZTVNSt3__117bad_function_callE"
```

原因：opentui 的 C++ 部分（yoga、各种 shim）是 **zig 自带的 libc++** 编的，
符号在 `std::__1` 命名空间；而 NDK 的 `libc++_shared.so` / `libc++_static.a` 用
`std::__ndk1`。两边混链就必然缺符号。剩下的未解析 C++ 符号一共 **20 个**
（`std::__1::bad_function_call` 的 vtable/typeinfo、`std::logic_error` 家族、
`operator new/delete` 等）。

## 6. 三条解下去的路（按性价排序）

**A. 全用 NDK 的 libc++（推荐）**
把 opentui 的所有 C++ 编译单元改成用 NDK 头（`-nostdinc++ -isystem <ndk>/usr/include/c++/v1`），
然后静态链 `libc++_static.a` + `libc++abi.a`。全部落在 `__ndk1`，符号自洽。
成本：给 `build.zig` 的 C++ flags 加两三个 flag（yoga flags 表 + 各 shim 的 flags）。

**B. 全用 zig 的 libc++**
把 zig 自带的 `lib/libcxx/src/*.cpp` + `lib/libcxxabi/src/*.cpp` 交叉编成
`libcxxzig.a`，一起链进去。难点：libc++ 的 C 头包装要求其 `include` 排在系统头之前，
直接 `-isystem` 会报 `<cerrno> tried including <errno.h> but didn't find libc++'s ...`
（zig 自己在内部用一套特殊 include 组合，显式复现需要额外试错）。

**C. 补齐 20 个符号的 stub**
写一个小 TU 提供这些 vtable/typeinfo/operator new。最容易出成果，但 vtable 布局
靠自己声明，只在"这些异常真被抛出"时有风险。

## 6b. A 线实测结果（2026-11-04，在设备上）

做法：给 `addYogaDependencies` 加 `-nostdinc++ -isystem <ndk>/usr/include/c++/v1`，
把 `link_libcpp` 关掉，改为链 NDK 的 `c++_static` / `c++abi`。

- 编译命令行确认生效（日志里能看到 `-nostdinc++ -isystem .../c++/v1`，
  并且 `-lc++_static` 出现在链接参数里）。
- 但产物 `libopentui.a` 里的引用仍然落在 `std::__1`（`nm -u` 可见
  `_ZTVNSt3__117bad_function_callE`），说明 **zig 仍把自带的 libc++ 头排在用户
  flag 之前**，NDK 的 `__config_site`（定义 `_LIBCPP_ABI_NAMESPACE __ndk1`）没被采纳。
- 尝试直接 `-D_LIBCPP_ABI_NAMESPACE=__ndk1` 覆盖：zig 的 libc++ 头会崩
  （`math.h: FP_NAN / FP_INFINITE undeclared`），不可行。
- 结论：**A 在"设备上用 Termux zig 编 C++"这个组合下走不通**，不是因为思路错，
  而是 zig 的 libc++ 头与 NDK 的 libc++ ABI 不能在同一个编译单元里混。

### A 的正确落地位置是 CI

CI runner 是 x86_64，可以跑 **NDK 自带的 clang**（`aarch64-linux-android30-clang`），
于是：

- C/C++ 部分交给 NDK clang（天然是 `__ndk1`，链 `libc++_static.a` 自洽）；
- Zig 部分交给 zig（`-Dlibrary-target=aarch64-linux-android.30`）；
- 两者产出的 .o/.a 一起打包成 `libopentui.so`。

在设备上做这件事的唯一障碍是"NDK 的 clang 是 x86_64 二进制，跑不起来"。

## 7. 复现用的本机落点

- `~/tmp/buns/bun-linux-aarch64-android/bun`：官方 android bun（1.4.4）
- `~/tmp/otui`：opentui 源码 + 我们打的 `-Dsysroot` 补丁（`build.zig.orig` 是原版）
- `~/tmp/android-ndk-r27c`：NDK r27c（只用到 sysroot；另外给 `30/` 里补了
  `libpthread.so`、`librt.so` → `libc.so` 的软链，NDK 本身没有这两个）
- `~/tmp/libopentui.so` + `~/tmp/libc++_shared.so`：已经能编出来的 bionic .so（卡在 dlopen）
- `~/tmp/ocsrc`：opencode v2 源码（api.github.com tarball，83 MB）
- `~/tmp/otcore`：`@opentui/core` npm 包解包

## 9. A 线跑通了（CI，2026-11-04）✅

`spike/libopentui-android/build.sh` + `.github/workflows/spike-libopentui-android.yml` 现可一键产出
**能在 android bun 里 dlopen 的** `libopentui.so`：

```
run 41687307711 → completed/success
  size: 20,503,304 bytes
  OK: 没有未解析的 C++ ABI 符号
  兼容层符号 pthread_tryjoin_np: OK
  导出的 FUNC 数: 2024
```

设备侧实测（官方 android bun 1.4.4）：

```
$ bun ffi2.ts
dlopen OK
symbol call OK, handle = null
```

### 工作分工（关键：谁编什么）

| 部分 | 谁编 | 原因 |
|---|---|---|
| opentui 核心（Zig）+ C 依赖（miniaudio/lcms2/libwebp） | `zig build -Dlibrary-target=aarch64-linux-android.30` | 只产 `.a`，不链接；zig 会在链接阶段报 `unable to provide libc`，**但 .a 已经产出**，我们忽略该错误 |
| yoga 20 个 `.cpp` + `yoga-bridge.cpp` | NDK `aarch64-linux-android30-clang++` | 天然 `std::__ndk1`，符号自洽 |
| `compat.c`（`pthread_tryjoin_np`） | NDK `…-clang`（**必须按 C 编**） | bionic 没有这个 glibc 扩展；用 clang++ 编会被名字 mangle |
| 合并成 `.so` | NDK `clang++ -shared -static-libstdc++` | 静态链 libc++，无运行时依赖 |

### build.zig 需要的三处补丁

1. android 下给 translate-c / module 注入 NDK sysroot 的 include（`-Dsysroot=`）。
2. `module.link_libc = false`：静态库阶段不链 libc，交给 NDK clang++。
3. `-Dandroid-cxx-external=true`：跳过 build.zig 自己的 C++ 编译（yoga 交给 NDK clang++）。

## 8. 另一个发现：opentui 有官方逃生口

`@opentui/core` 的 `resolveNativeLibraryPath()` 先看 **`OTUI_ASSET_ROOT`**：
若设置为绝对目录，会用 `$OTUI_ASSET_ROOT/@opentui/core/libopentui.so`。
所以将来我们自己的 bionic `libopentui.so` 不必替换 npm 包，wrapper 里设个环境变量即可。
另外 `process.platform` 在 android 上是 `"android"`，`getNativeAssetDescriptor` 会直接抛
"not supported"，需要把 `process.platform` 在编译期 define 成 `linux`（上游
`apply-platform-patch.sh` 就是这么干的）。
