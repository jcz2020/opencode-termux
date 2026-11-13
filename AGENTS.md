# PROJECT KNOWLEDGE BASE

**Generated:** 2026-11-13 · **Commit:** 1400fb7 · **Branch:** main

## OVERVIEW
在 Termux/aarch64 上构建并发布 opencode。源码线（主线）自编 opencode + libopentui + bun-pty，tag `v<ver>+termux<N>`；镜像线（备选）重打包上游 bionic 二进制 + libnoheap，tag `v<ver>+mirror<N>`。当前发布 `v2.3.0+termux3`，runtime bundle 内置 git/rg/gh/fd/jq/busybox。

## 其他项目：只读审查 + 提 issue，不直接改（强制）

本仓库之外的任何项目（尤其是同级目录的 `../opencode-app`）默认**只读**：

- 发现问题只在对应项目提 issue，不修改文件、不提交、不 push、不打 tag、
  不改 CI、不发 release/APK/AAB。
- 提 issue 前说明：仓库、标题、正文要点、影响范围；用户已明确要求提 issue 时可直接执行。
- 只有用户明确要求“修改某个其他项目”时，才进入修改流程，并且必须先说明：
  1. 为什么要动这个项目，与当前任务是什么关系；
  2. 准备修改哪些文件、执行哪些命令；
  3. 风险是什么、准备怎么验证；
  4. 等用户明确回复“可以 / 继续 / 同意”后再执行。
- 未经明确许可，不得替用户决定其他项目的版本号、发布节奏或回滚。

## WHERE TO LOOK
| 任务 | 位置 | 备注 |
|---|---|---|
| 打包/安装/冒烟 | `scripts/` | 先读 `scripts/AGENTS.md` |
| 原生编译 | `spike/*/build.sh`、`src/noheap.c` | 只能在 x86_64 跑 |
| 发版/跟进上游 | `.github/workflows/` | tag 规则见“网络/发布” |
| 用户可见行为 | `README.md` / `README.en.md` | 改行为必须同步 |
| 历史踩坑 | `docs/LESSONS.md` | 部分结论会过期 |

## CODE MAP（入口点）
| 入口 | 作用 | 运行位置 |
|---|---|---|
| `make source-deb` | 三份源码 → 四个件 → ABI 校验 → deb + bundle | x86_64/CI |
| `make deb` | 上游包 → 解包 → 加 shim → deb | 设备 |
| `make runtime-bundle` | deb/rootfs → tar.zst + manifest | 设备 |
| `make install` | dpkg -i 最新 dist/*.deb，清旧 diversion | 设备 |
| `make smoke` / `make smoke-service` | TUI 渲染 / 2.3.0 后台服务 ensure | 设备 |
| `make smoke-static` / `make smoke-release` | 静态体检 / release 装机冒烟 | 任意 / 设备 |
| `scripts/e2e-scenarios.sh` | 沙箱 6 交互 + 2 落盘核对 | 设备 + 模型 |

## STRUCTURE

```
Makefile            入口目标（见 COMMANDS）
src/noheap.c        关 bionic 堆 tagging 的 LD_PRELOAD shim
scripts/            取源码/打包/安装/冒烟/推送（细节见 scripts/AGENTS.md）
scripts/termux-tools.lock  git/rg/gh/fd/jq/busybox 与依赖的固定版本 + sha256
scripts/check-tool-updates.sh  对比 lock 与 Termux Packages 索引
spike/*/build.sh    源码线真正的编译逻辑，被 build-source-deb.sh 调用
.github/workflows/  build-deb-source · build-deb · watch-upstream(6h) · watch-tools(每日) · smoke-device · spike-*
docs/               BUILD 编译指南 · LESSONS 踩坑全集 · spike-android-bun 开发记录
cache/ build/ dist/ gitignore；make clean 连 dist/ 一起删
```

## 包内布局（关键约束）

两条线的布局不同，别按一套改：

| 文件 | 源码线（`+termux`） | 镜像线（`+mirror`） |
|---|---|---|
| `bin/opencode` | wrapper：设 `LD_PRELOAD`、`OPENTUI_NATIVE_LIB`、`BUN_PTY_LIB` | wrapper：只设 `LD_PRELOAD` |
| `bin/opencode.real` | 自己编 + strip（约 200 MiB） | 上游二进制 |
| `lib/opencode/libnoheap.so` | ✓ | ✓ |
| `lib/opencode/libopentui.so` + `opentui.h` | ✓（自编） | — |
| `lib/opencode/librust_pty.so` | ✓（自编） | — |
| `lib/opencode/opencode-updater.sh` | ✓（更新脚本） | ✓ |
| `lib/opencode/libopencode-crhandler.so` | — | ✓（上游自带） |

- **真二进制必须留在 `bin/`**：它有 `RUNPATH=$ORIGIN/../lib/opencode`；镜像线上游二进制还依赖 `DT_NEEDED` 第一项 `libopencode-crhandler.so`。
- 包名沿用 `opencode`，版本加后缀 → `dpkg -i` 是升级；所有文件归 dpkg 管，不要回到 dpkg-divert 手工方案。

## CONVENTIONS
- shebang 分流：设备脚本用 `#!/data/data/com.termux/files/usr/bin/bash`（Android 没有 `/usr/bin/env`），CI/通用脚本用 `#!/usr/bin/env bash`。
- 版本：下一修订号 = 已有最大 `+termux<N>` + 1，不覆盖已发布 release。
- 改用户可见行为同步 README；文档里的数字和链接会过期，改完顺手核对。

## ANTI-PATTERNS
- 不要 upx 压二进制（动态段不可见，DT_NEEDED/RUNPATH 修复失效）；不要挪 `opencode.real` 出 `bin/`。
- 镜像线不要 `LD_PRELOAD` crhandler（已是 `DT_NEEDED`），只 preload `libnoheap.so`。
- 不要在正在运行的 opencode 会话里 `dpkg -i` 新版本：会替换它自己的后台服务并取消当前命令；安装与 `make smoke` 分开执行。
- YAML：内联值后不能跟 `# 注释`；`run: |` 里不要嵌 heredoc，用 `printf` 拼字符串。
- 脚本层的 SIGPIPE、归档、umask 陷阱见 `scripts/AGENTS.md`。

## COMMANDS

```sh
make fetch VERSION=2.3.0 && make deb VERSION=2.3.0        # 镜像线
NDK_ROOT=... PATH=... make source-deb VERSION=2.3.0 REV=3 # 源码线，仅 x86_64/CI
make install && make smoke                                # 设备：TUI + 后台服务
make smoke-service                                       # 只测后台服务（隔离 XDG）
make smoke-static && make check-16kb                      # 任意
make check-tool-updates                                   # lock 里的工具是否有新版
make smoke-release TAG=v2.3.0+termux3                     # release 装机冒烟
bash scripts/e2e-scenarios.sh ~/tmp/oc-sandbox            # 沙箱，勿在仓库跑
```
- `make source-deb` 需要 NDK r27c、**zig 0.17.0**（脚本按 opentui `.zig-version` 严格比对）、bun、cargo + `aarch64-linux-android`、jq；`API=28` 可换 API level（默认 30）。
- `make verify-abi` 依赖 dist/build 解包产物；日常直接调 `scripts/verify-abi.sh`。

## 源码线的六个硬坑

1. **原生库 / JS / 包版本必须对齐**。`@opentui/*` 与 `libopentui.so` 不一致时，
   静态检查看不出来，运行时才报 `ot_session_get_renderer_state failed: InvalidArgument`。
   `build-source-deb.sh` 从 opencode 的 catalog 读版本，把 0.8.0/0.8.1 提到 **0.8.2**
   （更早的 `build.zig` 还在用 zig 0.16 API），并用 `jq` 同步 catalog 里所有
   `@opentui/*`；**catalog 改过就必须删 `bun.lock` 重装**，否则 hash 不匹配。
   打包前 `verify-abi.sh` 会静态比对符号表。
2. **Zig 的 libc++ 与 NDK 的 libc++ 不能混链**（`std::__1` vs `std::__ndk1`）。
   分工：zig 只产 `.a`（`-Dlibrary-target=...`，不链接），NDK clang++ 编 yoga，
   再 `-shared -static-libstdc++` 合并成 `.so`。
3. **bionic 没有 `pthread_tryjoin_np`**，由 `spike/libopentui-android/compat.c` 补。
   必须用 **clang 按 C** 编；用 clang++ 会被 mangle，等于白补。
4. **Android 15/16 的 16 KB 页对齐**。NDK r27 默认按 4 KB 链接，产出的
   `.so` 在 16 KB 页设备上加载失败。`libopentui.so` / `libnoheap.so` 的链接行
   必须带 `-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384`；
   `librust_pty.so` 通过 `RUSTFLAGS` 的 `-C link-arg=...` 透传。`opencode.real`
   用 bun 的 Android 模板（已 16 KB 对齐），构建后也做门禁。
   `scripts/check-16kb-pages.py` 会检查每个 ELF 的所有 `PT_LOAD.p_align >= 0x4000`；
   打包前、runtime bundle、`make smoke-static` / `make check-16kb` 都会跑。
5. **runtime bundle 只是“文件来源”，不是执行位置**。App 端受 Android 10+ W^X 限制，
   不能执行 `filesDir/usr/bin/git`；`opencode-app` 的 `prepare-jnilibs.sh` 会把它
   复制成 `libgit.so` / `librg.so`，运行时从 `nativeLibraryDir` 符号链接回
   `usr/bin`。所以 bundle 新增工具时必须同时更新 App 侧映射，改完用
   `bundle-termux-tools.sh` + `prepare-jnilibs.sh` 两端验证。
6. **2.3.0 的 wrapper 不能经过 `/system/bin/linker64`**。后台服务用
   `process.execPath` 重新 exec 自己；经 linker 启动时 execPath 变成 linker64，
   子进程执行 `linker64 serve --service`，报 `expected absolute path: "serve"`。
   wrapper 必须直接 `exec "$P/bin/opencode.real"`。`smoke-static.sh` 会拒绝含
   linker64 的 wrapper，`make smoke-service` 用隔离 XDG 验证服务拉起。

另外：CI 用官方 `bun-linux-aarch64-android`（`BUN_RELEASE=bun-v1.4.4`），
不需要自己交叉编 bun。bun 1.4 的 isolated 安装会把包放到
`node_modules/.bun/...` 隐藏目录，找 `@opentui/core` / `bun-pty` 要用 `find`/`os.walk`，
不要写死 `node_modules/<pkg>`。

## 网络 / 发布（本机实测，结论会过期）
- github.com 时通时不通；api.github.com / objects.githubusercontent.com / npm 稳定。下载一律走 release asset API（不拼 `releases/download/...` 直链）。
- push 先 `git push origin main`；TLS RST 时用 `scripts/push-api.sh`（blob→tree→commit→ref）。远端 SHA 必然不同但 tree 一致，进度在 `.git/api-push-state`；恢复后先 fetch 核对再 force。
- API 建 tag 不触发 push 事件 → 发版/跟进用 `gh workflow run`。
- 镜像线 tag 匹配 `'v*\+mirror*'`（glob 里 `+` 要转义），另有 if 兜底。
- 上游 `releases/latest` 指向 v1；v2 要自己按 semver 取最大。npm 的 aarch64 只到 1.19.5（v1），v2 只能源码编。

## 验证
`make smoke-static` →（装机）`make smoke` → `scripts/e2e-scenarios.sh`。**“能渲染”不等于“能用”**：曾漏掉 `Missing OpenTUI asset`，TUI 起来后一发消息就崩；CI 绿 ≠ 事做成了（`$GITHUB_OUTPUT` 没写成时 step 仍报 success）。

## NOTES
- **为什么需要 shim**：Android 11+ bionic 给堆指针打 top-byte tag（`0xb4000077…`），bun FFI 当 JS number 传给 libopentui 超过 2^53 → `Pointer exceeds safe integer range`。`src/noheap.c` 启动时 `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)`，wrapper 用 `LD_PRELOAD` 加载；与编译无关（2.1.4/2.2.5 崩法相同）。
- **wrapper 修复状态**：机制见硬坑 6。`+termux1` 的旧 linker64 wrapper 已在 `+termux2` 修复；`smoke-static` / `make smoke-service` 做回归。
- 建议上游把 `mallopt(...)` 放进 `libopencode-crhandler.so`，之后镜像线 wrapper 与 `libnoheap.so` 可删。
