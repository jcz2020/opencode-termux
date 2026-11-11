# opencode-termux

[![build-deb-source](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml/badge.svg)](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml)
[![release](https://img.shields.io/github/v/release/jcz2020/opencode-termux)](https://github.com/jcz2020/opencode-termux/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**在 Termux / Android 上真正跑得起来的 [opencode](https://opencode.ai)。**

[English](README.en.md) · [自己编译](docs/BUILD.md) · [原理与开发记录](docs/spike-android-bun.md)

---

## 为什么需要它

官方 opencode 的 Linux 版是 glibc 二进制，在 Termux（bionic）上根本跑不起来。
社区的 Termux 包虽然能装，但到了 **Android 11 及以上**（本项目在 Android 16 / API 36 上验证），
一进 TUI 就崩：

```
Error: Pointer exceeds safe integer range
```

根源在 bionic：它给堆指针打 top-byte tag，`malloc` 返回的地址长这样 —— `0xb4000077f0c1b6f0`。
bun 的 FFI 把这个指针当 JS number 传给 libopentui，数值超过 `2^53` 就报错了。
**这是运行时的问题，跟怎么编译无关** —— 2.1.4 和 2.2.5 崩法一模一样。

我们把这个问题解决了，而且不依赖任何第三方的 Termux 打包产物：

| 组件 | 怎么来的 |
|---|---|
| `opencode` 本体 | 用官方 Android 版 Bun 编译上游源码 |
| `libopentui.so`（TUI 渲染） | Zig + NDK 自行编译 |
| `librust_pty.so`（执行命令、终端面板） | Rust + NDK 自行编译 |
| `libnoheap.so`（关掉堆 tagging） | 本仓库里 6 KB 的 C 代码 |

---

## 安装

### 前提

- Android 11 或更高（更低版本没试过，不敢保证）
- 已适配 Android 15/16 的 **16 KB 页**设备：所有 ELF 的 `PT_LOAD` 均按 16 KB 对齐
- [Termux](https://termux.dev)（F-Droid 版和 GitHub 版都行）
- 架构 **aarch64**（现在的安卓手机基本都是；本项目只提供 aarch64 包）

### 一键安装与升级（推荐）

国内网络自动启用加速镜像与多通道重试：

```sh
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/jcz2020/opencode-termux/main/scripts/install-termux.sh | bash
```

> **海外 / 直连环境**：
> ```sh
> curl -fsSL https://raw.githubusercontent.com/jcz2020/opencode-termux/main/scripts/install-termux.sh | bash
> ```

脚本会自动感知网络环境、优选加速通道并校验 SHA-256。已有安装时直接作为升级工具运行。

### 日常检查与更新

安装后，输入官方更新命令即可直接接管并升级到本项目最新适配版本：

```sh
opencode update            # 检查并更新到最新版本
opencode update --check    # 仅检查是否有新版本
```

> 💡 **安全拦截保障**：本包已深度拦截官方更新通道，将检查源与更新器重定向至本项目适配库，绝不会下载官方 Linux glibc 脚本导致 Termux 环境崩溃；国内网络下自动并发多源加速与断点续传。

### 手动安装方式

如果想手动下载 `.deb` 包安装：

```sh
# 当前最新版本：v2.2.7+termux2
pkg install -y curl jq
id=$(curl -sS "https://api.github.com/repos/jcz2020/opencode-termux/releases/tags/v2.2.7+termux2" \
     | jq -r '.assets[] | select(.name|endswith(".deb")) | .id')
curl -sSL -C - -H 'Accept: application/octet-stream' -o opencode.deb \
  "https://api.github.com/repos/jcz2020/opencode-termux/releases/assets/$id"
dpkg -i opencode.deb
```

### 装完验证

```sh
opencode --version      # → opencode v2.2.7
oc                      # 短链，和 opencode 完全等价
```

直接跑 `opencode` 就进 TUI。
**如果主界面能进，但一发消息就崩**，那不是装坏了 —— 是免费额度用完了
（会提示 `You've used today's free messages`），换个模型或者等额度重置即可。

---

## 使用方式（TUI 与 Web UI 双模式）

本项目不仅支持终端 TUI，还**全量编译并内联了官方 Web UI 资产**，手机端或电脑端浏览器均可秒开图形界面！

### 1. 终端交互模式（TUI）
```sh
opencode
```
进入官方终端 TUI 界面，支持代码高亮与交互面板。

### 2. 网页图形界面模式（Web UI）
手机屏幕小、在终端排版看代码太累？运行内置的 Web 服务，用手机浏览器（Chrome、Kiwi、Firefox）或局域网内的电脑/平板直接访问现代化图形界面：

```sh
# 本地监听（仅限手机本机浏览器访问）
opencode serve

# 局域网共享（允许同一 Wi-Fi 下的电脑或平板访问）
opencode serve --hostname 0.0.0.0 --port 4096
```

启动后控制台会输出访问地址（形如 `http://127.0.0.1:4096`），在浏览器打开即可畅享：
- 🌟 **全量离线内联**：前端资源随包打包，完全脱离外部 CDN，本地秒开；
- 📱 **多项目与多标签切换**：支持工作区文件树浏览、Markdown 代码高亮渲染、Git Diff 审查；
- 🔒 **自带安全鉴权**：支持配置密码（`OPENCODE_SERVER_PASSWORD`）或一次性会话配对码。

> 💡 **提示**：如果你不想在 Termux 里手敲命令行、希望点桌面图标即开 + 后台守护保活 + 全面屏手势沉浸体验，可以关注配套的独立客户端 [OpenCode for Android](https://github.com/jcz2020/opencode-app)。

---

## 常见问题

**Q：装完提示 `opencode: command not found`？**
A：装完执行一次 `hash -r` 让 shell 重新扫 PATH；再确认 `$PREFIX/bin` 确实在 PATH 里。

**Q：一进 TUI 就崩，报 `Pointer exceeds safe integer range`？**
A：说明 `libnoheap.so` 没被加载。用 `dpkg -S $PREFIX/lib/opencode/libnoheap.so` 查一下，
没输出就是没装上，重新装一次包。

**Q：一进 TUI 就崩，报 `Missing OpenTUI asset ...`？**
A：包版本对不上 —— `libopentui.so` 和 JS 侧的 `@opentui/*` 必须是同一个版本。
去 release 页面拿最新的 deb 重装。

**Q：TUI 正常，但发消息报 `You've used today's free messages`？**
A：免费模型的额度用完了，不是 bug。`/models` 换一个，或者 `/connect` 配上自己的 key。

**Q：`oc` 是什么？**
A：就是个短链，指向 `opencode`。包本身不装它 —— 以前用 `install-opencode.sh`
手工装过的话已经有了；没有的话自己建一个：`ln -s $PREFIX/bin/opencode $PREFIX/bin/oc`。

**Q：能升级吗？**
A：能。包名沿用 `opencode`，版本号是 `上游版本+termux<N>`，
所以 `dpkg -i` 新包就是正常升级，不冲突，`apt` 也不会把你顶回旧版。

**Q：和 Hope2333 的 `opencode-termux` 包冲突吗？**
A：包名一样，只能二选一。先 `dpkg -r opencode` 卸掉旧的再装。

**Q：支持 x86_64 / 32 位吗？**
A：目前只提供 aarch64。

**Q：能自己编译吗？**
A：能，见 [docs/BUILD.md](docs/BUILD.md)。

---

## 两种打包方式

| 方式 | release tag | 包版本 | 依赖 | 产物大小 |
|---|---|---|---|---|
| **源码编译（主线）** | `v<ver>+termux<N>` | `<ver>+termux<N>` | 官方 Android Bun + NDK + Zig + Rust | 68 MB |
| 镜像重打包（备选） | `v<ver>+mirror<N>` | `<ver>+mirror<N>` | 第三方 Termux 打包产物 | 82 MB |

主线走源码编译：**除了 opencode 源码本身，不依赖任何第三方打包产物**。
`watch-upstream` 每 6 小时查一次上游 release，有新版本就自动编译并发布。

---

## 装到机器上是什么样

源码线（主线）的包会装这些东西：

| 路径 | 作用 |
|---|---|
| `bin/opencode` | 包装脚本：设好三个环境变量，再 exec 真正的二进制 |
| `bin/opencode.real` | 真正的 opencode 二进制（约 200 MiB） |
| `lib/opencode/libnoheap.so` | 关掉 bionic 的堆 tagging —— TUI 崩溃的关键就在这 |
| `lib/opencode/libopentui.so` | 我们自己编的 TUI 原生库（bionic） |
| `lib/opencode/librust_pty.so` | 我们自己编的 PTY 库（跑命令、终端面板） |
| `lib/opencode/opentui.h` | 原生库头文件，给要写 FFI 的插件用 |

包装脚本干的活就三件：

```sh
LD_PRELOAD=.../libnoheap.so          # 关堆 tagging
OPENTUI_NATIVE_LIB=.../libopentui.so  # 告诉 opentui 原生库在哪
BUN_PTY_LIB=.../librust_pty.so        # 告诉 bun-pty 库在哪
```

---

## 踩过的坑

完整清单在 [docs/LESSONS.md](docs/LESSONS.md)。其中最值得记住的一条：

> **「步骤显示成功」和「事情真的做成了」是两回事。**
> 这个项目里好几个 bug 都是 CI 绿的、测试也过，但该做的事压根没发生 ——
> 比如冒烟只测渲染，测不出「一用就崩」；
> 比如 `$GITHUB_OUTPUT` 没写进去，dispatch 静默跳过了，step 却报 success。
> 所以现在：冒烟会**真发一条 prompt**，校验会**静态比对 FFI 符号**，
> 每次改动都会**跑一遍 e2e 脚本**（6 个交互场景 + 2 项落盘核对）。

## 为什么不能直接用官方包

opencode 官方在 npm 上只发布到 **v1 家族**（`opencode-linux-arm64` 最高 1.19.5），
v2 的 aarch64 二进制压根不存在，只能自己编译。而编译需要两样不好搞的东西：

1. **能在 bionic 上跑的 Bun**（早期得自己把 bun 源码交叉编译到 bionic）。
   现在不用折腾了：官方直接发 `bun-linux-aarch64-android`（1.4.4），我们用的就是它。
2. **bionic 版 `libopentui.so`**（Zig 写的库，要交叉编译，还得处理 libc++ 的 ABI 问题）——
   这个我们已经解决了。

所以「自己造一个安卓 bun」这件事现在是不需要的，真正要自己编的是那两个原生库。

---

## 致谢

**我们不给 opencode 打补丁，只是让它能在 bionic 上跑起来。**
下面这些项目是一切成立的前提：

- **[anomalyco/opencode](https://github.com/anomalyco/opencode)** — opencode 本体（MIT），
  我们编译的就是它的源码。[opencode.ai](https://opencode.ai)
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — 官方提供了 `bun-linux-aarch64-android`
  构建，我们用它编译 opencode（MIT）。
- **[anomalyco/opentui](https://github.com/anomalyco/opentui)** — TUI 的原生库，
  我们为 bionic 交叉编译了它（MIT）。
- **[sursaone/bun-pty](https://github.com/sursaone/bun-pty)** — PTY 库，
  我们为 bionic 交叉编译了它（MIT）。
- **[Android bionic](https://android.googlesource.com/platform/bionic/)** —
  `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` 的行为依据
  就在 bionic 的 `<malloc.h>` 里；整个修复就是「读懂它，改掉一个进程级开关」。
- **[Termux](https://termux.dev)** — `dpkg`/`apt` 这条打包路径、umask 077 的坑、tmux 冒烟的手法。
- **[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux)**（幽零小喵）——
  我们最早是从它的实现里读懂了包内布局和那些「不能做什么」的边界，
  它的 `libopencode-crhandler.so`（SIGSYS→ENOSYS）思路也给了我们启发。
  **不过本项目的主线不依赖它的产物。**

本仓库**不包含**任何上游二进制（`cache/`、`dist/` 都在 `.gitignore` 里），
构建时按需下载并校验 sha256。

---

## License

本项目自己的代码（`src/` + `scripts/` + `spike/` + `Makefile`）是 MIT，见 [LICENSE](LICENSE)。
打进包里的 opencode 二进制仍归上游（MIT），归属说明见 [NOTICE](NOTICE)。
