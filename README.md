# opencode-termux

[![build-deb-source](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml/badge.svg)](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml)
[![release](https://img.shields.io/github/v/release/jcz2020/opencode-termux)](https://github.com/jcz2020/opencode-termux/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**在 Termux / Android 上能真正用起来的 [opencode](https://opencode.ai)。**

[English](README.en.md) · [自己出包](docs/BUILD.md) · [原理与开发记录](docs/spike-android-bun.md)

---

## 为什么需要它

官方 opencode 的 Linux 版是 glibc 二进制，直接在 Termux（bionic）上跑不了；
社区的 Termux 包虽然能用，但在 **Android 11 及以上**（本项目验证到 Android 16 / API 36）
一进 TUI 就崩：

```
Error: Pointer exceeds safe integer range
```

根因是 bionic 给堆指针打 top-byte tag（`malloc` 返回 `0xb4000077f0c1b6f0`），
bun 的 FFI 把这个指针当 JS number 传给 libopentui，超过了 `2^53` 就抛错。
**跟编译无关，是运行时问题** —— 2.1.4 和 2.2.5 一样崩。

本项目把它解决掉了，而且**不依赖任何第三方 Termux 打包产物**：

| 组件 | 怎么来的 |
|---|---|
| `opencode` 本体 | 用官方 Android 版 Bun 编译上游源码 |
| `libopentui.so`（TUI 渲染） | Zig + NDK 自己编 |
| `librust_pty.so`（跑命令 / 终端面板） | Rust + NDK 自己编 |
| `libnoheap.so`（关堆 tagging） | 本仓库 6 KB C 代码 |

---

## 安装

### 前提

- Android 11 或更高（低版本也能装，但不保证；本项目在 Android 16 上验证）
- [Termux](https://termux.dev)（F-Droid 版或 GitHub 版都行）
- 架构 **aarch64**（绝大多数现代手机；本项目只提供 aarch64 包）

### 一条命令

```sh
pkg install -y xz-utils curl
curl -LO "https://github.com/jcz2020/opencode-termux/releases/download/v2.2.5+termux1/opencode_2.2.5+termux1_aarch64.deb"
dpkg -i opencode_2.2.5+termux1_aarch64.deb
```

### `github.com` 连不上时（国内网络常见）

本机实测 `github.com` 直连不通，但 `api.github.com` 通。走 release 的 asset API：

```sh
id=$(curl -sS "https://api.github.com/repos/jcz2020/opencode-termux/releases/tags/v2.2.5+termux1" \
     | jq -r '.assets[] | select(.name|endswith(".deb")) | .id')
# -C - 支持断点续传；网络抖动断了就再跑一次同一条命令
curl -sSL -C - -H 'Accept: application/octet-stream' -o opencode.deb \
  "https://api.github.com/repos/jcz2020/opencode-termux/releases/assets/$id"
dpkg -i opencode.deb
```

没有 `jq` 就 `pkg install jq`。

> 网络不稳时 `curl` 可能报 `SSL_read: unexpected eof while reading` 并留下一个
> **不完整**的 deb。`dpkg -i` 会报 `unexpected end of file`。重跑同一条 `curl` 即可
> （带 `-C -` 会接着下，不会从头来）。下载完可以核对大小：
> `ls -l opencode.deb` 应该在 68 MB 左右，明显偏小就是没下完。

### 装完验证

```sh
opencode --version      # → opencode v2.2.5
oc                      # 短链，等价于 opencode
```

`opencode` 直接进 TUI。**如果能进主界面但一发消息就崩**，那不是装坏了，
是 free 额度用完了（会提示 `You've used today's free messages`），换个模型或等额度重置即可。

---

## 常见问题

**Q：装完 `opencode` 提示找不到命令？**
A：`dpkg -i` 后 `hash -r`；确认 `$PREFIX/bin` 在 `PATH` 里。

**Q：一进 TUI 就崩，报 `Pointer exceeds safe integer range`？**
A：shim 没加载。检查 `dpkg -S $PREFIX/lib/opencode/libnoheap.so` 有没有输出；
没有就重装包。

**Q：一进 TUI 就崩，报 `Missing OpenTUI asset ...`？**
A：包版本不对（`libopentui.so` 与 JS 侧 `@opentui/*` 必须同版本）。
重新下载最新 release 装上即可。

**Q：TUI 正常但发消息报 `You've used today's free messages`？**
A：opencode 免费模型额度用完，不是 bug。`/models` 换一个，或 `/connect` 配自己的 key。

**Q：`oc` 是什么？**
A：短链。之前用 `install-opencode.sh` 装过的话就有；没有的话
`ln -s $PREFIX/bin/opencode $PREFIX/bin/oc`。

**Q：能升级吗？**
A：能。包名沿用 `opencode`，版本是 `上游版本+termux<N>`，`dpkg -i` 新包就是升级，
不会和旧版本冲突，也不会被 `apt` 顶回去。

**Q：和 Hope2333 的 `opencode-termux` 包冲突吗？**
A：包名相同，二选一。装本项目前先 `dpkg -r opencode`。

**Q：支持 x86_64 / 32 位吗？**
A：目前只提供 aarch64。

**Q：能自己出包吗？**
A：能，见 [docs/BUILD.md](docs/BUILD.md)。

---

## 两条出包线

| 线 | release tag | 包版本 | 依赖 | 产物 |
|---|---|---|---|---|
| **源码构建（主线）** | `v<ver>+termux<N>` | `<ver>+termux<N>` | 官方 Android Bun + NDK + Zig + Rust | 68 MB |
| 镜像重打包（备选） | `v<ver>+mirror<N>` | `<ver>+mirror<N>` | 第三方 Termux 打包产物 | 88 MB |

主线是源码构建：**除 opencode 源码本身，什么第三方打包产物都不依赖**。
`watch-upstream` 每 6 小时看上游 release，一有新版本就自动出包并发布。

---

## 包里装了什么

源码线（主线）装到 `$PREFIX` 下：

| 路径 | 作用 |
|---|---|
| `bin/opencode` | wrapper：设好三个环境变量后 exec 真正的二进制 |
| `bin/opencode.real` | 真正的 opencode 二进制（210 MB） |
| `lib/opencode/libnoheap.so` | 关 bionic 堆 tagging（解决 TUI 崩溃的关键） |
| `lib/opencode/libopentui.so` | 自己编的 TUI 原生库（bionic） |
| `lib/opencode/librust_pty.so` | 自己编的 PTY 库（跑命令 / 终端面板） |
| `lib/opencode/opentui.h` | 原生库的头文件（给需要自己写 FFI 的插件用） |

wrapper 做的三件事：

```sh
LD_PRELOAD=.../libnoheap.so          # 关堆 tagging
OPENTUI_NATIVE_LIB=.../libopentui.so  # 告诉 opentui 原生库在哪
BUN_PTY_LIB=.../librust_pty.so        # 告诉 bun-pty 库在哪
```

---

## 上游构建线背景（为什么不能直接用官方包）

opencode 官方在 npm 上只发布到 **v1 家族**（`opencode-linux-arm64` 最高 1.19.5），
v2 的 aarch64 二进制**不存在**，只能从源码编。而从源码编需要两样难搞的东西：

1. **Android 版 Bun**（bun 源码交叉编译到 bionic）—— 现在有解了：官方就发
   `bun-linux-aarch64-android`（1.4.4），本项目用的就是它。
2. **bionic 版 `libopentui.so`**（Zig 库，要交叉编译 + 处理 libc++ ABI）—— 本项目解决了。

所以"自己造一个安卓 bun"这件事，现在是**不需要**的；真正要自己编的是那两个原生库。

---

## 致谢 / 引用

**本项目不打 opencode 的补丁，我们做的是让它能在 bionic 上跑起来。**
下面这些项目是它能成立的前提：

- **[anomalyco/opencode](https://github.com/anomalyco/opencode)** — opencode 本体（MIT），
  我们编译的就是它的源码。[opencode.ai](https://opencode.ai)
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — 官方提供了 `bun-linux-aarch64-android`
  构建，本项目用它编译 opencode（MIT）。
- **[anomalyco/opentui](https://github.com/anomalyco/opentui)** — TUI 的原生库，
  本项目为 bionic 交叉编译了它（MIT）。
- **[sursaone/bun-pty](https://github.com/sursaone/bun-pty)** — PTY 库，
  本项目为 bionic 交叉编译了它（MIT）。
- **[Android bionic](https://android.googlesource.com/platform/bionic/)** —
  `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` 的行为依据
  就是 bionic 的 `<malloc.h>`；本项目的关键修复就是"读懂它 + 改一个进程级开关"。
- **[Termux](https://termux.dev)** — `dpkg`/`apt` 打包路径、umask 077 的坑、`tmux` 冒烟手法。
- **[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux)**（幽零小喵）—
  本项目最早是从它的实现里读懂了包内布局与那些"不能做什么"的边界；
  它的 `libopencode-crhandler.so`（SIGSYS→ENOSYS）思路也给了我们启发。**本项目的主线不依赖它的产物。**

本仓库**不包含**任何上游二进制（`cache/`、`dist/` 都在 `.gitignore` 里），
构建时按需下载并校验 sha256。

---

## License

本项目自己的代码（`src/` + `scripts/` + `spike/` + `Makefile`）为 MIT，见 [LICENSE](LICENSE)。
打进包里的 opencode 二进制仍归上游（MIT），归属说明见 [NOTICE](NOTICE)。
