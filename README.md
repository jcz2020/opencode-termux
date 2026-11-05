# opencode-termux（自制适配线）

[![build-deb](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb.yml/badge.svg)](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb.yml)
[![release](https://img.shields.io/github/v/release/jcz2020/opencode-termux)](https://github.com/jcz2020/opencode-termux/releases)

自己的 Termux/aarch64 opencode 打包项目：**取上游 bionic 二进制 → 打自己的补丁 shim →
出自己的 deb**。不编译 opencode、不编译 bun，分钟级出包，不跟上游发布节奏。

已在本机跑通：`opencode v2.2.5`，`dpkg -l opencode` → `2.2.5+termux1`，
TUI 冒烟通过（`make smoke`）。

## 为什么需要这个项目

Hope2333 的包在这台机器（Android 16 / API 36）上 TUI 起不来：

```
Error: Pointer exceeds safe integer range  at ... createContext ... Tui.run
```

根因是 bionic 堆指针 top-byte tagging（`malloc` 返回 `0xb4000077f0c1b6f0`），
bun 的 FFI 把指针当 JS number 交给 libopentui，超过 `Number.MAX_SAFE_INTEGER`
就抛错。**跟编译无关，是运行时问题**——2.1.4 和 2.2.5 都一样崩。

修法 6 KB C：进程启动时 `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL,
M_HEAP_TAGGING_LEVEL_NONE)`，之后 `malloc` 返回 `0x7d831e9b00`。
见 `src/noheap.c`。

## 安装形态（无 dpkg-divert）

| 路径 | 内容 |
|---|---|
| `$PREFIX/bin/opencode` | wrapper：`LD_PRELOAD=libnoheap.so` 后 exec `.real` |
| `$PREFIX/bin/opencode.real` | 上游真二进制。它 `RUNPATH=$ORIGIN/../lib/opencode`，所以必须留在 `bin/` |
| `$PREFIX/lib/opencode/libopencode-crhandler.so` | 上游自带（`DT_NEEDED` 第一项，SIGSYS/close_range） |
| `$PREFIX/lib/opencode/libnoheap.so` | 本项目加的 shim |

包名沿用 `opencode`，版本 `上游版本+termux<N>` → `dpkg -i` 是升级不是冲突，
所有文件都归 dpkg 管（`dpkg -S` 可查），`apt` 也不会再把它顶回上游旧版。

## 两种出包方式

| 方式 | 命令 / 入口 | 依赖 | 产物 |
|---|---|---|---|
| **源码构建（推荐）** | `make source-deb VERSION=2.2.5`，CI 是 `build-deb-source` | 只有：官方 android bun + NDK + zig + rust | 68 MB |
| 二进制重打包 | `make deb`，CI 是 `build-deb` | 上游/第三方的 bionic 二进制 | 82 MB |

源码线把四个件全部自己编：

| 件 | 怎么来的 |
|---|---|
| `opencode.real` | 官方 android bun + `--target=bun-linux-aarch64-android` 编译上游源码 |
| `libopentui.so` | zig 0.17 编 opentui 核心（.a）+ NDK clang++ 编 yoga → 静态链 libc++ |
| `librust_pty.so` | cargo + NDK clang 交叉编 bun-pty |
| `libnoheap.so` | 本仓库的 6KB shim（关 bionic 堆 tagging） |

`watch-upstream` 每 6 小时看上游 release，一有新版本就 dispatch **源码构建**并发布。
详见 `docs/spike-android-bun.md`。

### 校验

```sh
make smoke-static    # 解包 deb 静态体检：文件/架构/依赖/版本/FFI 符号/dpkg 元数据
make verify-abi      # 只比对 @opentui/core 的 nativeSymbols 与 .so 导出符号
make smoke-release TAG=v2.2.5+termux2   # 设备上：下载 deb → dpkg -i → tmux 冒烟
```

> ABI 校验不是装饰：JS 侧 `@opentui/*` 与原生库版本不一致时，运行时才报
> `ot_session_get_renderer_state failed: InvalidArgument`，很难定位。静态比对能提前抓到。

## 安装（直接装 release）

CI 在 tag 上自动出包并发布：

```sh
curl -LO "https://github.com/jcz2020/opencode-termux/releases/download/v2.2.5+termux1/opencode_2.2.5+termux1_aarch64.deb"
dpkg -i opencode_2.2.5+termux1_aarch64.deb
opencode --version        # v2.2.5
```

`github.com` 不通时（本机就是这样）走 release **asset API**：

```sh
id=$(curl -sS "https://api.github.com/repos/jcz2020/opencode-termux/releases/tags/v2.2.5+termux1" \
     | jq -r '.assets[] | select(.name|endswith(".deb")) | .id')
curl -sSL -H 'Accept: application/octet-stream' -o opencode.deb \
  "https://api.github.com/repos/jcz2020/opencode-termux/releases/assets/$id"
dpkg -i opencode.deb
```

装完 `opencode` / `oc` 直接进 TUI；如果崩在 `Pointer exceeds safe integer range`，
说明 shim 没加载（`dpkg -S $PREFIX/lib/opencode/libnoheap.so` 应该有输出）。

## 用法

```sh
make fetch VERSION=2.2.5     # 取上游包进 cache/，按 .MTREE sha256 校验
make deb   VERSION=2.2.5     # → dist/opencode_2.2.5+termux1_aarch64.deb
make install                 # dpkg -i（自动清理老的 dpkg-divert 安装）
make smoke                   # tmux 真 tty 起 TUI，断言主界面渲染 + 版本
make clean
```

换版本只改 `VERSION`；`REV=2` 可以覆盖已发布的同版本。

### 出包（CI）

`.github/workflows/build-deb.yml`：`git push` 一个 tag（形如 `v2.2.5+termux1`）→
runner 装 NDK 编 shim（`CC=aarch64-linux-android24-clang`）→ `make deb` → 校验包结构 →
建 release 并上传 `.deb` + `.sha256`。也可 `gh workflow run build-deb -f version=2.2.5 -f rev=1`
手动跑（只出 artifact，不发 release）。

## 上游三种构建线（读 Makefile / produce-local.sh / build-bionic.sh 得到）

| 线 | 做法 | 代价 |
|---|---|---|
| Wrapper | `npm pack opencode-linux-arm64@<ver>`（官方 glibc/musl 二进制）→ `bun-termux-loader` 做 ELF 手术（interp/动态段/bunfs shim） | 轻；但 TUI 要另配 bionic `libopentui.so`，缺了就 "tui:absent" |
| Native（B 线） | `bun script/build.ts --target=opencode-linux-arm64` 用 **android bun 1.4.0** 从 opencode v2 源码编译 | 重：android bun（1.4.2 在 bionic 直接 segfault，钉 1.4.0）、zig 编的 bionic `libopentui.so`（含 TLSDESC shim）、`openat2_shim`、磁盘/内存闸门 |
| Compressed | B 线 + UPX | 同上 |

补充事实（今天实测）：npm 的 `opencode-linux-arm64` 最高 **1.19.5**（v1 家族），
v2 的 aarch64 二进制在 npm 上没有，只能 B 线从源码编——所以本项目当下
"I own 打包 + 补丁，不 own 二进制"。要完全独立就得把 B 线那套工具链搬过来：

1. android bun 1.4.0（bun 源码交叉编译到 bionic，最重的一块）
2. `zig` 交叉编 bionic `libopentui.so`（含 TLS descriptor shim + FFI 负坐标 guard）
3. opencode v2 源码 + `--target=opencode-linux-arm64` 编译
4. seccomp shim（`SIGSYS` → `ENOSYS`，我们已经知道它是干什么的）
5. 打包（本项目这部分已经做完，直接复用）

第 1、2 步是真正的门槛，不是"等上游"——是几周的活。第 3–5 步本项目已经就位，
所以哪天拿到 android bun + bionic libopentui，改成源码线只是换 `scripts/build-deb.sh`
里的取件步骤，包结构不用动。

## 致谢 / 引用

**本项目的二进制不是我们编译的**，全部取自上游构建；我们只做了运行时补丁与打包。
没有下面这些项目，这个仓库一行都跑不起来。

- **[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux)**（幽零小喵）—
  Termux/bionic 原生构建，以及 `libopencode-crhandler.so`（SIGSYS→ENOSYS、close_range）
  seccomp shim。本项目的 `cache/` 取件源、包内布局（`bin/opencode.real` 与
  `RUNPATH=$ORIGIN/../lib/opencode` 的强约束）、以及「不压 UPX / 不 preload crhandler」
  这些设计边界，都是从他们的实现里读出来的。MIT。
- **[Hope2333/bun-termux-loader](https://github.com/Hope2333/bun-termux-loader)** —
  bun standalone 二进制的 ELF 手术（interp / 动态段 / bunfs shim），是上游 Wrapper 线的核心。
- **[anomalyco/opencode](https://github.com/anomalyco/opencode)** — opencode 本体（MIT），
  也就是本文里所有「上游」二进制的来源。[opencode.ai](https://opencode.ai)
- **[Android bionic](https://android.googlesource.com/platform/bionic/)** —
  `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` 与
  `M_HEAP_TAGGING_LEVEL_TBI` 的行为依据是 bionic 的 `<malloc.h>`；本项目的全部修复
  就是「读懂它 + 改一个进程级开关」。
- **[Termux](https://termux.dev)** — `dpkg-deb` / `apt` 打包路径、umask 077 导致 control
  目录权限不足的坑、以及 `tmux` 冒烟手法。

本仓库**不包含**上游二进制与产物（`cache/`、`dist/` 均在 `.gitignore` 里），
`make fetch` 会自己按 `.MTREE` sha256 校验后下载。

## 备注

- 本机 `github.com` 直连不可用；`api.github.com` / `objects.githubusercontent.com` /
  `registry.npmjs.org` 通。`fetch.sh` 因此走 release **asset API**（302 → 签名 URL）。
- **`git push` 同样不通**（TLS RST）。推提交用 `scripts/push-api.sh`：
  Git Data API 重放 blob/tree/commit，tree 与本地逐字节一致（脚本会断言），
  但 commit SHA 因 GitHub 把时区归一化成 UTC 而必然不同。
- 保守起见 `Depends: bash, clang`：wrapper 用 bash，`make deb` 现场编 shim 需要 clang。
- 想给上游提修复：把 `mallopt(...TAGGING_LEVEL_NONE)` 塞进他们的
  `libopencode-crhandler.so`（那个 shim 已经在做 SIGSYS 的同类活儿），
  之后 wrapper 和 `libnoheap.so` 都能删掉。

## License

本项目自己的代码（`src/noheap.c` + `scripts/` + `Makefile`）为 MIT，见 `LICENSE`。
打包进去的 opencode 二进制仍归上游（MIT）。
