# opencode-termux 项目知识库

> 目标：自己的 Termux/aarch64 opencode 打包线——取上游 bionic 二进制 → 打补丁 shim → 出自己的 deb。
> 不编译 opencode、不编译 bun。详细背景与上游三条构建线的分析见 `README.md`。

**Status:** 已在本机跑通 · `opencode 2.2.5+termux1` · `make smoke` = OK

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
├── dist/                 产物 deb + .sha256（80 MB，gitignore）
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
make fetch VERSION=2.2.5   # 取上游包进 cache/，.MTREE sha256 校验
make deb   VERSION=2.2.5   # → dist/opencode_2.2.5+termux1_aarch64.deb
make install               # dpkg -i 最新 dist/*.deb
make smoke                 # tmux TUI 冒烟（失败非 0）
make clean                 # 清 build/ 与 dist/
```

换版本只改 `VERSION`；`REV=2` 覆盖同版本已发布产物。

## 网络约束（本机实测）

- `github.com` **不可用**；`api.github.com` / `objects.githubusercontent.com` /
  `registry.npmjs.org` 可用 → 下载一律走 **release asset API**（302 到签名 URL），
  不要拼 `releases/download/...` 直链。
- **`git push` 也走不通**（github.com:443 TLS RST：
  `error:0A000126:SSL routines::unexpected eof while reading`）。推送用
  `scripts/push-api.sh`（Git Data API：blob → tree → commit → update ref）。
  注意远端 commit SHA 与本地**不一致**（GitHub 把 author/committer 时区归一化成
  UTC，commit 原始字节不同），但 tree 逐字节一致，脚本会断言这点；
  推送进度记在 `.git/api-push-state`，不依赖本地有远端对象。
- npm 的 `opencode-linux-arm64` 最高 **1.19.5**（v1 家族）；**v2 的 aarch64 二进制
  在 npm 上没有**，只能从源码编（上游 B 线）。

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
