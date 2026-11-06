# opencode-termux 项目知识库

> 目标：在 Termux/aarch64 上跑起 opencode。两条产线：
> **源码线（主线）** 自己编 opencode + libopentui + bun-pty → tag `v<ver>+termux<N>`；
> **镜像线（备选）** 重打包上游 bionic 二进制 + libnoheap → tag `v<ver>+mirror<N>`。
> 文档分工：`README.md` 用户向 · `README.en.md` 英文 · `docs/BUILD.md` 编译指南 ·
> `docs/LESSONS.md` 踩坑全集 · `docs/spike-android-bun.md` 开发记录。
> 改用户可见行为时同步 README。

**现状**：`v2.2.5+termux2` 已发布并通过 `make smoke`；源码线已在本机和 CI 跑通。

## 为什么需要 shim（别把它删了）

Android 11+ 的 bionic 给堆指针打 top-byte tag，`malloc` 返回 `0xb4000077f0c1b6f0`；
bun 的 FFI 把它当 JS number 传给 libopentui 时超过 2^53 →
`Error: Pointer exceeds safe integer range`。**这是运行时问题，与编译无关**
（2.1.4 / 2.2.5 崩法相同）。`src/noheap.c` 在进程启动时执行
`mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)`，
由 wrapper 用 `LD_PRELOAD` 加载。

## STRUCTURE

```
Makefile               入口（fetch/deb/source-deb/runtime-bundle/install/smoke/verify-abi/clean）
src/noheap.c           关堆 tagging 的 6 KB LD_PRELOAD shim
scripts/
  fetch.sh             取上游 pkg.tar.xz（走 release asset API）+ .MTREE sha256 校验
  build-deb.sh         镜像线：解包 → 编 shim → 组装 rootfs → dpkg-deb → bundle
  build-source-deb.sh  源码线：取三份源码 → 编四个件 → 验 ABI → 打包 → bundle
  build-runtime-bundle.sh 制作独立的 tar.zst 运行时 bundle + runtime-manifest.json
  install.sh           dpkg -i（会先清理老的 dpkg-divert 手工安装）
  smoke.sh             tmux 真 tty 起 TUI，断言主界面 + 版本
  smoke-static.sh      解包 deb 做静态体检，不需要设备
  smoke-release.sh     下载某个 release 的 deb → 安装 → 真机冒烟
  e2e-scenarios.sh     沙箱里跑 6 个真实交互 + 2 项落盘核对
  verify-abi.sh        FFI 符号 / bionic 依赖比对（build-source-deb 会调用）
  abi-symbols.py       精确提取 @opentui/core 的 nativeSymbols 键
  push-api.sh          github.com 的 git push 不通时，用 Git Data API 推提交
spike/{libopentui,bun-pty,opencode}-android/build.sh
                      源码线真正的编译逻辑，不是一次性脚本（build-source-deb 直接调用）
.github/workflows/    build-deb-source（主线）· build-deb（镜像线）·
                      watch-upstream（每 6h）· smoke-device · spike-*
cache/ build/ dist/   gitignore；`make clean` 会连 dist/ 一起删
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
| `lib/opencode/libopencode-crhandler.so` | — | ✓（上游自带） |

- **真二进制必须留在 `bin/`**：它有 `RUNPATH=$ORIGIN/../lib/opencode`；镜像线的上游
  二进制还依赖 `DT_NEEDED` 第一项 `libopencode-crhandler.so`。挪走就找不到这些库。
- **不要 `LD_PRELOAD` crhandler**（镜像线）：它已经是 `DT_NEEDED`，只需 preload
  `libnoheap.so`。
- **不要 upx 压二进制**：压过之后动态段不可见，`DT_NEEDED`/RUNPATH 修复失效。
- 包名沿用 `opencode`，版本加后缀 → `dpkg -i` 是升级不是冲突；所有文件归 dpkg 管。
  不要再用 dpkg-divert 手工方案。

## COMMANDS

```sh
# 设备上可跑（镜像线 + 冒烟）
make fetch VERSION=2.2.5          # 上游包进 cache/，按 .MTREE 校验 sha256
make deb   VERSION=2.2.5          # → dist/opencode_2.2.5+mirror1_aarch64.deb
make install                      # dpkg -i 最新 dist/*.deb（镜像线包 Depends: clang）
make smoke                        # 需已安装 + tmux；失败非 0
make smoke-static                 # 解包 dist/ 最新 deb，无需设备
make smoke-release TAG=v2.2.5+termux2   # 从 release 下载、安装、真机冒烟
bash scripts/e2e-scenarios.sh [sandbox]
                                  # 6 个交互 + 2 项落盘；需模型/网络；
                                  # 默认沙箱 $HOME/tmp/oc-sandbox，绝不在仓库目录跑

# 只能在 x86_64 Linux / CI 跑（NDK 的 clang 是 x86_64，Termux 上跑不了）
NDK_ROOT=/path/to/ndk \
  PATH=/path/to/zig-0.17.0:/path/to/bun:$PATH \
  make source-deb VERSION=2.2.5 REV=1
                                  # → dist/opencode_2.2.5+termux1_aarch64.deb
```

- `make source-deb` 需要 NDK r27c、**zig 0.17.0**（脚本会拿 `spike` 拉下来的
  opentui `.zig-version` 严格比对）、bun、cargo + `aarch64-linux-android` target、jq。
- 发布版本号：下一修订号 = 已有最大 `+termux<N>` + 1，**不要覆盖已发布 release**
  （`watch-upstream` 已按这个规则算）。
- `make verify-abi` 依赖 `dist/`/`build/` 里的解包产物；日常直接用
  `scripts/verify-abi.sh <libopentui.so> <librust_pty.so> <@opentui/core 目录> <bun-pty 目录>`。
- `API=28 make source-deb ...` 可换 API level（默认 30）。

## 源码线的三个硬坑

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

另外：CI 用官方 `bun-linux-aarch64-android`（`BUN_RELEASE=bun-v1.4.4`），
不需要自己交叉编 bun。bun 1.4 的 isolated 安装会把包放到
`node_modules/.bun/...` 隐藏目录，找 `@opentui/core` / `bun-pty` 要用 `find`/`os.walk`，
不要写死 `node_modules/<pkg>`。

## 网络 / 发布（本机实测，结论会过期）

- `github.com` **时通时不通**；`api.github.com` / `objects.githubusercontent.com` /
  `registry.npmjs.org` 稳定。自动化脚本下载一律走 **release asset API**
  （302 到签名 URL），不要拼 `releases/download/...` 直链。
- 推送：先 `git push origin main`。失败典型报错是 github.com:443 TLS RST
  （`unexpected eof while reading`）→ 用 `scripts/push-api.sh`（blob → tree →
  commit → update ref）。API 推过的 commit SHA 与本地**必然不同**（GitHub 把时区
  归一化成 UTC），但 tree 逐字节一致；进度记在 `.git/api-push-state`。
  之后 `git push` 恢复时会 `fetch first`：先 `git fetch origin main` 核对 tree，
  再 `git push --force origin main` 对齐（仓库只有自己在推）。
- **API 建 tag 不会触发 `push` 事件** → 发版/跟进一律用 `gh workflow run`。
- 镜像线 tag 形如 `v2.2.5+mirror1`，workflow 的触发模式因此写成
  `'v*\+mirror*'`：GitHub glob 里 `+` 是特殊字符（前一个字符重复 ≥1 次），
  匹配字面量必须转义；不要写成 `v*-mirror`。job 里还有一层 `if` 兜底，
  源码线 tag（`+termux<N>`）不会误跑镜像线打包。
- 上游 `anomalyco/opencode` 的 `releases/latest` 指向 v1 维护线（1.19.5）；
  要 v2 主线必须自己拉 release 列表按 semver 取最大（`watch-upstream` 已这么做）。
- npm 的 `opencode-linux-arm64` 最高 1.19.5（v1），v2 的 aarch64 二进制不存在，
  只能源码编。

## 验证与常见坑

改完代码的最小验证顺序：`make smoke-static` →（装到设备）`make smoke` →
`bash scripts/e2e-scenarios.sh`。**“能渲染”不等于“能用”**：曾漏掉
`Missing OpenTUI asset`，TUI 起来后一发消息就崩。

- CI 绿 ≠ 事做成了：条件分支的 workflow 要确认输出真的产生
  （曾因 `$GITHUB_OUTPUT` 没写成导致 dispatch 静默跳过，step 仍报 success）。
- 不要写 `strings f | grep -q`：`grep -q` 提前退出会让 `strings` 收到 SIGPIPE，
  在 `set -o pipefail` 下整条管道被判失败。先落盘再匹配。
- 找 FFI 符号不要用宽泛 grep（`grep -oE 'ot_[a-z_]+:'` 会把注释/字符串算进来）；
  用 `scripts/abi-symbols.py` 精确取 `nativeSymbols` 的键。
- YAML：内联值后面不能跟 `# 注释`；`run: |` 块里不要嵌 heredoc，用 `printf` 拼字符串。
- Termux 的 umask 077 → `dpkg-deb` 会拒收 700 的 control 目录；打包后
  `find "$BUILD" -type d -exec chmod 755 {} +`。
- 大文件上别用 `dpkg-deb --fsys-tarfile | tar -xO | file -`（会拿到空输入）；
  先 `dpkg-deb -x` 解包再检查。
- shebang 不要“统一”：设备上跑的脚本用绝对路径
  `#!/data/data/com.termux/files/usr/bin/bash`（Android 没有 `/usr/bin/env`），
  CI 上跑的脚本才用 `#!/usr/bin/env bash`。
- `make clean` 会删 `dist/`；二进制/缓存本来就不进 git。

## 上游修复建议（可提 issue/PR）

把 `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` 加进上游
`libopencode-crhandler.so`（它已经在做 SIGSYS 同类 shim）——之后镜像线的 wrapper 与
`libnoheap.so` 都可以删掉。
