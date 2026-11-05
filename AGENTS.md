# opencode-termux 项目知识库

> 目标：做一套自己的 Termux/aarch64 opencode 打包线。
> 两条线：**A 重打包**（拿上游 bionic 二进制 → 打补丁 shim → 出 deb）
> 和 **B 源码编译**（opencode + libopentui + bun-pty 全部自己编，不依赖任何第三方打包产物）。
> 文档分工：`README.md` 面向用户（安装/FAQ）· `README.en.md` 英文版 ·
> `docs/BUILD.md` 自己编译的指南 · `docs/LESSONS.md` 经验教训 ·
> `docs/spike-android-bun.md` 开发过程记录。
> 改代码后如果影响用户可见行为，同步更新 README。

**Status:** 已在本机跑通 · `opencode 2.2.5+termux2`（源码线）· `make smoke` = OK ·
release `v2.2.5+termux2` 已发布

## OVERVIEW

本机（Termux / Android 16 / API 36 / aarch64）上，Hope2333 的 opencode 包 TUI 起不来：
`Error: Pointer exceeds safe integer range`。根因是 bionic 给堆指针打 top-byte tag
（`malloc` 返回 `0xb4000077f0c1b6f0`），bun 的 FFI 把指针当 JS number 交给 libopentui
时超过 2^53。**与编译无关，是运行时问题**（2.1.4 / 2.2.5 都一样崩）。

修法：`src/noheap.c`（6 KB）在进程启动时
`mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)`，
之后 `malloc` 返回 `0x7d831e9b00`。由 wrapper 用 `LD_PRELOAD` 加载。

## STRUCTURE

```
opencode-termux/
├── Makefile              fetch / deb / install / smoke / clean
├── src/noheap.c          关堆 tagging 的 LD_PRELOAD shim（唯一的"我们的代码"）
├── scripts/fetch.sh      取上游 pkg.tar.xz（走 release asset API）+ .MTREE sha256 校验
├── scripts/build-deb.sh  解包 → 编 shim → 组装 rootfs → dpkg-deb
├── scripts/install.sh    dpkg -i（自动清理老的 dpkg-divert 手工安装）
├── scripts/smoke.sh      tmux 真 tty 起 TUI，断言主界面渲染 + 版本，崩了 FAIL
├── scripts/push-api.sh   github.com 的 git push 不通时，用 REST API 推提交
├── cache/                上游包缓存（79 MB，gitignore）
├── dist/                 产物 deb + .sha256（gitignore）
├── NOTICE                上游二进制归属（LICENSE 保持纯 MIT 以便 GitHub 识别）
```

## 包内布局（关键约束）

| 装到位 | 内容 |
|---|---|
| `$PREFIX/bin/opencode` | wrapper：`LD_PRELOAD=libnoheap.so` 后 exec `.real` |
| `$PREFIX/bin/opencode.real` | 上游真二进制。**必须留在 `bin/`**：它 `RUNPATH=$ORIGIN/../lib/opencode` |
| `$PREFIX/lib/opencode/libopencode-crhandler.so` | 上游自带，`DT_NEEDED` 第一项（SIGSYS/close_range → ENOSYS） |
| `$PREFIX/lib/opencode/libnoheap.so` | 本项目 shim |

包名沿用 `opencode`，版本 `上游版本+termux<N>` → `dpkg -i` 是升级不是冲突，
所有文件归 dpkg 管（`dpkg -S` 可查），`apt` 不会顶回上游旧版。
**不要再用 dpkg-divert 手工方案**（历史遗留见 `~/opencode-fix/README.md`）。

## COMMANDS

```sh
# 二进制重打包线（拿上游 bionic 二进制）
make fetch VERSION=2.2.5   # 取上游包进 cache/，.MTREE sha256 校验
make deb   VERSION=2.2.5   # → dist/opencode_2.2.5+mirror1_aarch64.deb
make install               # dpkg -i 最新 dist/*.deb
make smoke                 # tmux TUI 冒烟（失败非 0）

# 源码编译线（不依赖任何第三方打包产物）
make source-deb VERSION=2.2.5 REV=1   # 需要 NDK_ROOT / zig 0.17 / bun / rust

# 校验
make smoke-static           # 解包 deb 做静态体检（不需要设备）
make smoke-release TAG=v2.2.5+termux2   # 从 release 拉 deb 装到设备再冒烟

make clean                 # 清 build/ 与 dist/
```

换版本只改 `VERSION`；`REV=2` 覆盖同版本已发布产物。

## 网络约束（本机实测）

- `github.com` **时通时不通**（2026-11-05 实测：上午还是 TLS RST，
  当天下午 `git push` 就连上了）。`api.github.com` / `objects.githubusercontent.com` /
  `registry.npmjs.org` 一直可用 → 下载一律走 **release asset API**（302 到签名 URL），
  不要拼 `releases/download/...` 直链。
- **推送：先试 `git push origin main`，不通再退回 API。**
  - `git push` 失败时的典型报错：github.com:443 TLS RST
    （`error:0A000126:SSL routines::unexpected eof while reading`）。
    这时用 `scripts/push-api.sh`（Git Data API：blob → tree → commit → update ref）。
  - 走 API 推过的远端，commit SHA 与本地**不一致**（GitHub 把 author/committer
    时区归一化成 UTC，commit 原始字节不同），但 tree 逐字节一致，脚本会断言这点；
    推送进度记在 `.git/api-push-state`，不依赖本地有远端对象。
  - 之后若 `git push` 通了，会被拒（`fetch first`，因为远端那些提交本地没有）。
    先 `git fetch origin main` 核对 tree 是否一致，然后
    `git push --force origin main` 把远端 SHA 与本地重新对齐
    （仓库只有自己在推，force 安全）。2026-11-05 实测走完这条，两边 SHA 就一致了。
- npm 的 `opencode-linux-arm64` 最高 **1.19.5**（v1 家族）；**v2 的 aarch64 二进制
  在 npm 上没有**，只能从源码编（上游 B 线）。

## 源码编译线（scripts/build-source-deb.sh）

四个组件全部现编，CI 是 `build-deb-source`：

| 件 | 怎么来的 |
|---|---|
| `libopentui.so` | zig 0.17 编 opentui 核心（.a）+ NDK clang++ 编 yoga → 静态链 libc++ |
| `librust_pty.so` | cargo + NDK clang 交叉编 bun-pty（termios 要补 android cfg） |
| `opencode.real` | 官方 android bun + `--target=bun-linux-aarch64-android` 编译上游源码 |
| `libnoheap.so` | 本仓库 `src/noheap.c` |

**版本对齐是这里唯一真正的坑**：JS 侧 `@opentui/*` 与原生库必须同版本，否则运行时
报 `ot_session_get_renderer_state failed: InvalidArgument`。opentui 0.8.0/0.8.1 的
`build.zig` 还在用 zig 0.16 的 API（`b.args`/`b.build_root`），0.17 编不动 →
统一钉 0.8.2，并用 `jq` 把 opencode catalog 里的 `@opentui/*` 一起提上去
（改完 catalog 必须删 `bun.lock` 重装，否则 hash 不匹配）。

出 deb 前跑 `scripts/verify-abi.sh`：比对 `@opentui/core` 的 `nativeSymbols` 与
`.so` 的导出符号，这一步能在 CI 里提前抓住版本不匹配。

## 经验教训（完整版见 docs/LESSONS.md）

最容易被忽略的一类坑：**表面全绿、实际没生效**。改代码前先看这几条：

1. **冒烟必须测真实交互**。"能渲染"过不了"一用就崩"（曾漏掉 `Missing OpenTUI asset`）。
2. **有条件分支的 workflow，要看输出是否真的产生**。曾因 `$GITHUB_OUTPUT` 没写成
   导致 dispatch 静默跳过，step 还报 success。
3. **算"下一个版本号"用「已有最大 +1」**，不是「已有最大」（否则 clobber 已发布 release）。
4. **多产线的 tag 命名空间必须一开始就分开**（源码线 `+termux<N>` / 镜像线 `+mirror<N>`）。
5. **原生库 / JS / 包版本三者对齐**，并在 CI 里静态校验（`scripts/verify-abi.sh`）。
6. `strings f | grep -q` 在 `set -o pipefail` 下会误判失败 → 先落盘再匹配。
7. YAML 里内联值后面不能跟 `# 注释`；块标量里不要嵌 heredoc。
8. `releases/latest` 可能指向维护线 → 自己按 semver 取最大。

## ANTI-PATTERNS

1. **不能把真二进制挪出 `bin/`**：`RUNPATH=$ORIGIN/../lib/opencode` + `DT_NEEDED
   libopencode-crhandler.so`，挪走就找不到 shim，进程起不来。
2. **不要 LD_PRELOAD crhandler**：它已经是 `DT_NEEDED` 第一项，重复加载没意义；
   只 preload `libnoheap.so`。
3. **不要用 `upx` 压这个二进制**：压过之后动态段不可见，`DT_NEEDED`/RUNPATH 修复失效
   （上游 `transplant-upx` 也是"必须在最后一步"）。
4. **Termux umask 077**：`dpkg-deb` 要求 control 目录 ≥0755，构建后必须 chmod
   （`build-deb.sh` 已处理）。
5. **`make clean` 会删 `dist/`**：想留产物先拷走。
6. 二进制/缓存不进 git（`.gitignore` 覆盖 `cache/` `build/` `dist/`）。
7. **不要用宽泛 grep 找 FFI 符号**：`grep -oE 'ot_[a-z_]+:'` 会把注释/字符串里的
   也算进来，误报一片。要精确取 `nativeSymbols` 对象的键（`scripts/abi-symbols.py`）。
8. **不要写 `strings f | grep -q`**：`grep -q` 提前退出会让 `strings` 收到 SIGPIPE，
   在 `set -o pipefail` 下整条管道被判失败。先落盘再匹配。
9. **YAML 里的 heredoc**：块标量里的 `<<EOF` 内容如果缩进不对会破坏 YAML
   结构（GitHub 报 "Invalid workflow file"）。改用 `printf` 拼字符串。
   YAML 里内联值后面也不能跟 `# 注释`。

## ROADMAP（想彻底独立于上游时的清单）

1. android bun 1.4.0（bun 源码交叉编到 bionic；**1.4.2 在 bionic 直接 segfault**）← 最重
2. zig 交叉编 bionic `libopentui.so`（TLSDESC shim + FFI 负坐标 guard）← 次重
3. opencode v2 源码 + `bun script/build.ts --target=opencode-linux-arm64`
4. seccomp shim（SIGSYS→ENOSYS）
5. 打包 ← **已完成，可直接复用**

3–5 已就位；做完 1–2 只需把 `build-deb.sh` 的取件步骤换成源码编译，包结构不动。

## 上游修复建议（可提 issue/PR）

把 `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)` 加进上游
`libopencode-crhandler.so`（那个 shim 已经在做 SIGSYS 同类工作）——
之后 wrapper 与 `libnoheap.so` 都可以删掉。
