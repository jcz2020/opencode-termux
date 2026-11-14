# 自己编译

> 写给想自己编一份、或者想改点什么的贡献者。
> 只想用现成的包 → 看 [README](../README.md#安装)。

源码编译这条路，四个组件全部自己编，**不依赖任何第三方的 Termux 打包产物**：

| 组件 | 怎么编 | 编出来多大 |
|---|---|---|
| `libopentui.so` | Zig 0.17 编 opentui 核心（`.a`）+ NDK clang++ 编 yoga，最后静态链 libc++ | 20 MB |
| `librust_pty.so` | cargo 配 NDK clang 交叉编译 bun-pty | 500 KB |
| `libnoheap.so` | 本仓库的 `src/noheap.c` | 6 KB |
| `opencode.real` | 官方 Android Bun 编译上游源码，然后 strip | 200 MiB |
| `opencode-pty` | 上游 npm 的 linux-arm64-musl 静态二进制（协议 8） | 3 MB |

运行时的独立 bundle 还会额外内置（deb 本身不带）：

| 工具 | 版本 | 用途 |
|---|---|---|
| `git` | 2.56.1（Termux） | agent 的 status/diff/add/commit/checkout/stash 等；含 HTTPS helper |
| `ripgrep` | 15.2.0（Termux） | opencode Grep/Glob |
| `gh` | 2.104.0（Termux） | GitHub CLI |
| `fd` | 10.5.2（Termux） | 文件查找 |
| `jq` | 1.8.2（Termux） | JSON 处理 |
| `busybox` | 1.38.0（Termux） | 常用 shell 工具集 |
| 依赖库 | libcurl / openssl / pcre2 / oniguruma / zlib / expat / iconv 等 | 固定 sha256，全部 16 KB 对齐 |

`opencode-pty` 不属于 Termux 工具集，由 `scripts/fetch-opencode-pty.sh` 从 npm
按 `opencode-pty.lock` 取固定版本，装到 deb/ bundle 的 `bin/opencode-pty`。

这些工具由 `scripts/bundle-termux-tools.sh` 收进 `runtime-*.tar.zst` 的
`usr/bin`、`usr/lib`、`usr/libexec/git-core`，并附带 git templates 与 CA 证书。
App 侧必须把可执行文件再复制成 `jniLibs` 的 `libgit.so` / `librg.so`，
否则 Android 10+ W^X 不允许从 `filesDir` 执行。

工具版本唯一来源是 `scripts/termux-tools.lock`。升级流程：

```sh
make check-tool-updates     # 对比 lock 与 Termux Packages，只报告不改文件
# 手动改 lock 的版本/路径/sha256
make smoke-static && make check-16kb
make smoke-service          # 设备
# 发新的 +termuxN，不要覆盖旧 release
make publish-tool-cache     # 把本次 lock 的 deb 缓存到 toolchain-cache release
```

`watch-tools` workflow 每天检查一次，只维护一个 issue，不自动改 lock、不自动发版。
`publish-tool-cache` 在 lock 变更时自动缓存整套 deb；构建时优先用
`toolchain-cache` 的内容寻址 tar.zst，再回退到 Termux 源。缓存不提交进 Git，
也不影响 runtime bundle 大小。

---

## 前置条件

| 工具 | 版本 | 怎么装 |
|---|---|---|
| NDK | r27c | <https://dl.google.com/android/repository/android-ndk-r27c-linux.zip> |
| Zig | **0.17.0**（必须和 opentui 的 `.zig-version` 一致） | <https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz> |
| Bun | 1.4.4（宿主机版，用来跑构建脚本） | <https://github.com/oven-sh/bun/releases> |
| Rust | stable + `aarch64-linux-android` target | `rustup target add aarch64-linux-android` |
| Python 3 | 3.8+（构建脚本解析版本、校验 16 KB 对齐） | `apt install python3` |
| jq / curl / tar / unzip | 任意版本 | `apt install jq curl` |

> ⚠️ Zig 的版本必须对上：opentui v0.8.0/0.8.1 的 `build.zig` 还在用 Zig 0.16 的 API
> （`b.args` / `b.build_root`，0.17 已经删了），所以我们把原生库固定在 **opentui 0.8.2**。

---

## 跑一遍

```sh
git clone https://github.com/jcz2020/opencode-termux.git
cd opencode-termux

export NDK_ROOT=$PWD/android-ndk-r27c
export PATH="$PWD/zig-x86_64-linux-0.17.0:$PWD/bun-linux-x64:$PATH"

make source-deb VERSION=2.3.0 REV=3
# → dist/opencode_2.3.0+termux3_aarch64.deb (+ .sha256)
```

装到设备上：

```sh
make install        # dpkg -i 最新的 dist/*.deb
make smoke          # 在 tmux 真 tty 里起 TUI，检查渲染和版本号
```

---

## 让 CI 帮你编

`.github/workflows/build-deb-source.yml`：

```sh
gh workflow run build-deb-source -f version=2.3.0 -f rev=3 -f publish=true
```

它会依次装上 bun/zig/NDK/rust，跑 `scripts/build-source-deb.sh`，产出 deb，
做一遍静态冒烟，最后建 release 并上传 `.deb` 和 `.sha256`。

`watch-upstream` 每 6 小时自动查上游 release，有新版本就触发这个 workflow。

---

## 脚本一览

| 脚本 | 干什么 |
|---|---|
| `scripts/build-source-deb.sh` | **主线**：取源码、编四个组件、拼 rootfs、`dpkg-deb`、自检 |
| `spike/libopentui-android/build.sh` | 只编 `libopentui.so` |
| `spike/bun-pty-android/build.sh` | 只编 `librust_pty.so` |
| `spike/opencode-android/build.sh` | 只编 `opencode.real`（含 `build.ts` 的 android 补丁） |
| `scripts/build-runtime-bundle.sh` | 组装可独立分发的 `runtime-*.tar.zst` + manifest |
| `scripts/fetch-opencode-pty.sh` | 按 `opencode-pty.lock` 取 2.3.0 持久 PTY 静态二进制 |
| `scripts/bundle-termux-tools.sh` | 把固定版本 git/rg/gh/fd/jq/busybox 与依赖收进 runtime bundle |
| `scripts/check-tool-updates.sh` | 对比 `termux-tools.lock` 与 Termux 仓库，只报告不自动更新 |
| `scripts/verify-abi.sh` | 比对 `@opentui/core` 要的 FFI 符号和 `.so` 导出的符号 |
| `scripts/smoke-static.sh` | 解包 deb 做静态体检（不需要设备） |
| `scripts/smoke-service.sh` | 设备上：隔离 XDG 启一次 2.3.0 后台服务 |
| `scripts/smoke-pty.sh` | 设备上：启动/停止 opencode-pty 持久 PTY daemon |
| `scripts/smoke-release.sh` | 设备上：下载 release、装上、tmux 冒烟，**真发一条 prompt** |
| `scripts/e2e-scenarios.sh` | 沙箱里跑 6 个真实交互场景（读文件/改文件/建文件/跑命令……）+ 2 项落盘核对 |

---

## 四个一定要知道的坑

### 1. 原生库和 JS 侧必须同版本

JS 侧的 `@opentui/core` 和原生 `libopentui.so` 版本对不上时，**只有运行时才会炸**：

```
NativeError: ot_session_get_renderer_state failed: InvalidArgument
```

因为 FFI 的结构体布局对不上，静态检查根本看不出来。所以：

- 原生库固定在 **opentui 0.8.2**
- 同时把 opencode 源码 `package.json` 里 `workspaces.catalog` 中所有 `@opentui/*` 一起提到 0.8.2
  （`build-source-deb.sh` 用 `jq` 改）
- 改完 catalog 一定要 **删掉 `bun.lock` 重装**，否则 hash 对不上

`scripts/verify-abi.sh` 会在打包前静态比对符号表，提前抓住这个问题。

### 2. Zig 编的 C++ 和 NDK 的 libc++ 不能混着链

opentui 的 C++ 部分（yoga 之类）是用 Zig 自带的 libc++ 编的，符号在 `std::__1`；
NDK 的 `libc++_shared.so` 用的是 `std::__ndk1`。混着链必然缺符号（大概 20 个）。

办法是**分工**：

```
zig build -Dlibrary-target=aarch64-linux-android.30   只产 .a，不链接
NDK clang++ 编 yoga *.cpp                              用 std::__ndk1
NDK clang++ -shared -static-libstdc++                  合并成 .so
```

> Zig 0.17 不肯给 android target「提供 libc」（`unable to provide libc for target …-android.30`），
> 所以 `.so` 不能由 Zig 直接链；编静态库那一步用 `module.link_libc = false` 绕过去。

### 3. bionic 没有 `pthread_tryjoin_np`

opentui 的 Zig 核心用了这个 glibc 扩展，bionic 里没有，一 `dlopen` 就失败：

```
cannot locate symbol "pthread_tryjoin_np"
```

`spike/libopentui-android/compat.c` 补上了它（6 行）。
**必须用 `clang` 按 C 编** —— 用 `clang++` 编会被 mangle 成 C++ 符号，等于白编。

### 4. Android 15/16 要求 16 KB 页对齐

16 KB 页设备要求 ELF 的每个 `PT_LOAD` 段 `p_align >= 0x4000`；NDK r27
和更早版本默认只按 4 KB（`0x1000`）链接，产出的 `.so` 会直接加载失败。
构建脚本里已经强制加上：

- `libopentui.so` / `libnoheap.so`：`-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`
- `librust_pty.so`：通过 `RUSTFLAGS` 透传同样的 `-C link-arg=...`
- `opencode.real`：使用官方 Android Bun 模板，本身已是 16 KB 对齐，构建后做硬性门禁

校验脚本（打包前、静态冒烟、runtime bundle 都会调用）：

```sh
python3 scripts/check-16kb-pages.py <opencode.real> <*.so ...>
make check-16kb                   # 解包最新 dist/*.deb 并校验
```

### 5. 2.3.0 的 wrapper 必须直接 exec `opencode.real`

2.3.0 起 TUI 会用 `process.execPath` 重新执行 `serve --service`。wrapper 如果
经过 `/system/bin/linker64`，Bun 会把 execPath 报成 linker64，子进程变成
`linker64 serve --service`，报 `expected absolute path: "serve"`，后台服务起不来。
所以 wrapper 最后必须是：

```sh
exec "$P/bin/opencode.real" "$@"
```

`smoke-static.sh` 会拒绝含 `linker64` 的 wrapper；`make smoke-service` 会用隔离
的 `XDG_STATE_HOME` 真正启动一次后台服务。

### 6. 2.3.0 的持久 PTY 需要 `opencode-pty` 和可写 socket 目录

2.3.0 的 agent shell 依赖 `opencode-pty` daemon。缺失时日志会刷：

```text
process daemon unavailable; spawning shell command instead
Executable not found in $PATH: "opencode-pty"
```

修复分两半：

1. 把上游 `@opencode/pty-linux-arm64-musl` 的静态二进制装到 `bin/opencode-pty`；
2. wrapper 注入 `OPENCODE_PTY_BIN` 和 `OPENCODE_PTY_SOCKET_DIR`。

socket 目录不能是 Android 的 `/tmp`（不可写），也不能太长（`SUN_LEN` 限制）。
wrapper 默认用 `${TMPDIR:-$P/tmp}/opty`；`make smoke-pty` 会真正启动/停止 daemon 验证。

---

## 想改点东西

- **换 opencode 版本**：`make source-deb VERSION=2.3.0`（上游 tag 形如 `v2.3.0`）
- **改 shim**：改 `src/noheap.c`，`make source-deb` 会重新编
- **改 TUI 行为**：opentui 的 Zig 源码在 `spike/libopentui-android/build.sh` 拉下来的那份里
- **换 API level**：`API=28 make source-deb`（默认 30）

改完记得跑：

```sh
make smoke-static                 # 静态体检
make smoke-service                # 2.3.0 后台服务启动（设备）
make smoke-pty                    # opencode-pty 持久 PTY（设备）
bash scripts/e2e-scenarios.sh     # 沙箱里跑真实场景
```

---

## 镜像线（老办法，留作备选）

不自己编原生库，直接拿上游/第三方的 bionic 二进制重新打包：

```sh
make fetch VERSION=2.2.5   # 取上游包到 cache/，按 .MTREE 校验 sha256
make deb   VERSION=2.2.5   # → dist/*.deb
make install
```

它的 tag 命名空间是 `v<ver>+mirror<N>`，和源码线的 `v<ver>+termux<N>` 分开，
两边不会互相覆盖 release。推 `v<ver>+mirror<N>` tag 会触发 `build-deb`
自动打包并发布；也可以手动 `gh workflow run build-deb -f version=... -f rev=... -f publish=true`。
