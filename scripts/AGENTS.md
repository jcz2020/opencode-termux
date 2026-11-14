# SCRIPTS KNOWLEDGE BASE

**Generated:** 2026-11-13 · **Commit:** 1400fb7

## OVERVIEW
打包、安装、冒烟、发布与推送的入口集合；被 Makefile、CI 和 `install-termux.sh` 调用。父级规则见仓库根 `AGENTS.md`。

## WHERE TO LOOK
| 任务 | 脚本 | 运行位置 |
|---|---|---|
| 取上游包并校验 | `fetch.sh` | 设备/CI |
| 镜像线打包 | `build-deb.sh` | 设备 |
| 源码线打包 | `build-source-deb.sh` | x86_64/CI |
| runtime bundle | `build-runtime-bundle.sh` → `bundle-termux-tools.sh` + `termux-tools.lock` | 设备/CI |
| 工具版本检查 | `check-tool-updates.sh` | 设备/CI |
| 工具 deb 缓存 | `publish-tool-cache.sh` | CI/维护者 |
| 持久 PTY 二进制 | `fetch-opencode-pty.sh` + `opencode-pty.lock` | 设备/CI |
| 安装 | `install.sh`、`install-termux.sh` | 设备 |
| 冒烟与回归 | `smoke.sh`、`smoke-service.sh`、`smoke-pty.sh`、`smoke-static.sh`、`smoke-release.sh`、`e2e-scenarios.sh` | 设备/任意 |
| 契约校验 | `verify-abi.sh`、`abi-symbols.py`、`check-16kb-pages.py` | 任意 |
| 推送 | `push-api.sh` | 设备 |

## PIPELINE
- 镜像线：`fetch.sh` → `build-deb.sh` → `build-runtime-bundle.sh`。
- 源码线：`build-source-deb.sh` 调 `spike/*/build.sh` 编四个件 → `verify-abi.sh` → deb → bundle。
- 安装：`install.sh`（dpkg -i，先清旧 diversion）或 `install-termux.sh`（多镜像、断点续传、SemVer 选最高 `+termux`、拦截 `opencode update`）。
- 验证：`smoke.sh`（tmux 真 tty）、`smoke-service.sh`（隔离 XDG 后台服务）、`smoke-pty.sh`（持久 PTY daemon）被 `make smoke` / `smoke-release.sh` 复用；`smoke-static.sh` 不需要设备；`e2e-scenarios.sh` 用沙箱。

## CONTRACTS
- `build-source-deb.sh VERSION REV` → `dist/opencode_<VERSION>+termux<REV>_aarch64.deb`；REV 只增不覆盖。
- `build-runtime-bundle.sh` 版本从 deb 文件名推断；镜像线必须显式传 `mirror<N>`，否则 manifest tag 错。
- `bundle-termux-tools.sh` 从 `termux-tools.lock` 读取固定版本/路径/sha256；`BUNDLE_TOOLS=0` 跳过。
- `check-tool-updates.sh` 只对比并报告，不修改 lock、不发 release；退出码 0=最新、2=有更新、1=错误。
- `publish-tool-cache.sh` 生成 `termux-tools-<lock-sha>.tar.zst` 并上传到 `toolchain-cache` release；`bundle-termux-tools.sh` 优先用它兜底。
- `fetch.sh` 只走 release asset API，按 `.MTREE` 的 sha256digest 校验。
- `push-api.sh` 走 blob→tree→commit→ref；进度在 `.git/api-push-state`，结束前断言 tree 一致。

## CONVENTIONS
- 全部 `set -euo pipefail`（`e2e-scenarios.sh` 例外：`set -uo pipefail`，失败要累计而不是立即退出）。
- 阶段输出统一 `==> ...`；错误写 stderr 并 `exit 1`（用法错误 `exit 2`）。
- 临时目录用 `mktemp -d` + `trap` 清理；不要写 `/tmp`（Termux 无写权限）。
- shebang 按运行位置分流，见根 `AGENTS.md`。

## ANTI-PATTERNS
- 不要 `strings f | grep -q`：SIGPIPE + pipefail 会误判；先落盘再匹配。
- 不要宽泛 grep 找 FFI 符号；用 `abi-symbols.py` 精确取 `nativeSymbols` 键。
- 不要 `dpkg-deb --fsys-tarfile | tar -xO | file -`；先 `dpkg-deb -x` 解包。
- 打包后 `find "$BUILD" -type d -exec chmod 755 {} +`（umask 077 会让 dpkg-deb 拒收 700 目录）。
- 不要在仓库目录跑 `e2e-scenarios.sh`；默认沙箱 `$HOME/tmp/oc-sandbox`。
- 安装与冒烟不要串成一条命令：安装会替换正在运行的服务，失败会连带取消验证。
- **wrapper 不要经过 `/system/bin/linker64`**：2.3.0 用 `process.execPath` 拉起 `serve --service`，Bun 会把 execPath 报成 linker64，服务报 `expected absolute path: "serve"`。必须直接 `exec "$P/bin/opencode.real"`；`smoke-static.sh` 已加门禁。
- `smoke-service.sh` 用隔离的 `XDG_STATE_HOME` 启独立端口，不会碰主服务；不要改成用默认 state 目录。
- `opencode-pty` 的 socket 目录必须可写且短于 `SUN_LEN`；Android 的 `/tmp` 不可写，wrapper 用 `${TMPDIR:-$P/tmp}/opty`。

## HOTSPOTS
- `install-termux.sh`（约 400 行）：镜像测速/续传/SemVer，改动需同时验证 `--check`、`--force`、`--dry-run`；`--version 2.3.0` 必须选同版本最高 `+termuxN`，不能硬编码 `+termux1`。
- `build-source-deb.sh`（286 行）：四件编排与 catalog 版本同步，最易破坏 ABI。
- `build-runtime-bundle.sh`（203 行）：布局、manifest、wrapper，改动需与 App 侧映射同步。
- `termux-tools.lock`：工具版本唯一来源；改 lock 必须重跑 16KB/接口/HTTPS 验证，并跑 `publish-tool-cache`。
- `smoke-service.sh`：2.3.0 service 启动链路；wrapper / execPath 回归会在这里暴露。

## COMMANDS
```sh
make smoke-static
make smoke-service
bash scripts/smoke.sh
bash scripts/smoke-release.sh v2.3.0+termux5
bash scripts/e2e-scenarios.sh ~/tmp/oc-sandbox
bash scripts/verify-abi.sh <libopentui.so> <librust_pty.so> <@opentui/core dir> <bun-pty dir>
```
