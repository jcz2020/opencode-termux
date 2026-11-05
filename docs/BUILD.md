# 自己出包（源码构建）

> 面向想自己编译、或想改点什么的贡献者。
> 只想装现成的 → 回 [README](../README.md#安装)。

源码线把四个件全部自己编，**不依赖任何第三方 Termux 打包产物**：

| 件 | 编法 | 产物体积 |
|---|---|---|
| `libopentui.so` | Zig 0.17 编 opentui 核心（`.a`）+ NDK clang++ 编 yoga → 静态链 libc++ | 20 MB |
| `librust_pty.so` | cargo + NDK clang 交叉编 bun-pty | 500 KB |
| `libnoheap.so` | 本仓库 `src/noheap.c` | 6 KB |
| `opencode.real` | 官方 Android Bun 编译上游源码 → strip | 210 MB |

---

## 前置条件

| 工具 | 版本 | 怎么装 |
|---|---|---|
| NDK | r27c | <https://dl.google.com/android/repository/android-ndk-r27c-linux.zip> |
| Zig | **0.17.0**（必须和 opentui 的 `.zig-version` 一致） | <https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz> |
| Bun | 1.4.4（host 版，用来跑构建脚本） | <https://github.com/oven-sh/bun/releases> |
| Rust | stable + `aarch64-linux-android` target | `rustup target add aarch64-linux-android` |
| jq / curl / tar / unzip | 任意 | `apt install jq curl` |

> ⚠️ Zig 版本必须对上：opentui v0.8.0/0.8.1 的 `build.zig` 还在用 Zig 0.16 的 API
> （`b.args` / `b.build_root`，0.17 已删），本项目因此把原生库钉在 **opentui 0.8.2**。

---

## 跑一次

```sh
git clone https://github.com/jcz2020/opencode-termux.git
cd opencode-termux

export NDK_ROOT=$PWD/android-ndk-r27c
export PATH="$PWD/zig-x86_64-linux-0.17.0:$PWD/bun-linux-x64:$PATH"

make source-deb VERSION=2.2.5 REV=1
# → dist/opencode_2.2.5+termux1_aarch64.deb (+ .sha256)
```

装到设备：

```sh
make install        # dpkg -i 最新 dist/*.deb
make smoke          # tmux 真 tty 起 TUI，断言渲染 + 版本
```

---

## CI 一键出包

`.github/workflows/build-deb-source.yml`：

```sh
gh workflow run build-deb-source -f version=2.2.5 -f rev=1 -f publish=true
```

它会：装 bun/zig/NDK/rust → 跑 `scripts/build-source-deb.sh` → 出 deb →
静态冒烟 → 建 release 并上传 `.deb` + `.sha256`。

`watch-upstream` 每 6 小时自动检查上游 release，有新版就 dispatch 这个 workflow。

---

## 脚本一览

| 脚本 | 干什么 |
|---|---|
| `scripts/build-source-deb.sh` | **主线**：取源码 → 编四个件 → 组 rootfs → `dpkg-deb` → 自检 |
| `spike/libopentui-android/build.sh` | 只编 `libopentui.so` |
| `spike/bun-pty-android/build.sh` | 只编 `librust_pty.so` |
| `spike/opencode-android/build.sh` | 只编 `opencode.real`（含 `build.ts` 的 android 补丁） |
| `scripts/verify-abi.sh` | 比对 `@opentui/core` 的 FFI 符号与 `.so` 导出符号 |
| `scripts/smoke-static.sh` | 解包 deb 做静态体检（无需设备） |
| `scripts/smoke-release.sh` | 设备上：下载 release → 装 → tmux 冒烟 → **真发一条 prompt** |
| `scripts/e2e-scenarios.sh` | 沙箱里跑 8 个真实交互场景（读/编辑/建文件/长命令…） |

---

## 三个必须知道的坑

### 1. 原生库与 JS 侧必须同版本

JS 侧的 `@opentui/core` 和原生 `libopentui.so` 版本不一致时，**运行时**才炸：

```
NativeError: ot_session_get_renderer_state failed: InvalidArgument
```

FFI 结构体布局对不上，静态看不出来。所以：

- 原生库钉在 **opentui 0.8.2**
- 同时把 opencode 源码 `package.json` 的 `workspaces.catalog` 里所有 `@opentui/*`
  一起提到 0.8.2（`build-source-deb.sh` 用 `jq` 做）
- 改完 catalog 要 **删掉 `bun.lock` 重装**，否则 hash 对不上

`scripts/verify-abi.sh` 会在出包前静态比对符号表，提前抓住这个问题。

### 2. Zig 编的 C++ 和 NDK 的 libc++ 不能混链

opentui 的 C++ 部分（yoga 等）用 Zig 自带的 libc++ 编，符号在 `std::__1`；
NDK 的 `libc++_shared.so` 用 `std::__ndk1`。混链必然缺符号（20 个左右）。

做法：**分工**

```
zig build -Dlibrary-target=aarch64-linux-android.30   → 只产 .a，不链接
NDK clang++ 编 yoga *.cpp                              → std::__ndk1
NDK clang++ -shared -static-libstdc++                  → 合并成 .so
```

> Zig 0.17 不肯为 android "provide libc"（`unable to provide libc for target …-android.30`），
> 所以 `.so` 不能由 Zig 直接链；静态库阶段用 `module.link_libc = false` 绕开。

### 3. bionic 缺 `pthread_tryjoin_np`

opentui 的 Zig 核心用了这个 glibc 扩展，bionic 没有 → `dlopen` 直接失败：

```
cannot locate symbol "pthread_tryjoin_np"
```

`spike/libopentui-android/compat.c` 补了它（6 行）。**必须用 `clang` 按 C 编**，
用 `clang++` 编会被 name-mangling 成 C++ 符号，白搭。

---

## 改点东西

- **换 opencode 版本**：`make source-deb VERSION=2.2.6`（上游 tag 形如 `v2.2.6`）
- **改 shim**：`src/noheap.c` → `make source-deb` 会重新编
- **改 TUI 行为**：opentui 的 Zig 源码在 `spike/libopentui-android/build.sh` 拉取的那份
- **换 API level**：`API=28 make source-deb`（默认 30）

改完记得跑：

```sh
make smoke-static                 # 静态体检
bash scripts/e2e-scenarios.sh     # 沙箱里跑真实场景
```

---

## 镜像线（老办法，保留着当备选）

不自己编原生库，直接拿上游/第三方的 bionic 二进制重打包：

```sh
make fetch VERSION=2.2.5   # 取上游包到 cache/，按 .MTREE 校验 sha256
make deb   VERSION=2.2.5   # → dist/*.deb
make install
```

它的 tag 命名空间是 `v<ver>+mirror<N>`，和源码线的 `v<ver>+termux<N>` 分开，
不会互相覆盖 release。
