# 经验教训

> 这个项目踩过的坑，按"坑的类型"归类。
> 每一条都注明**怎么发现的**——因为好几条都是"表面全绿、实际没生效"，那种坑最难查。

---

## 一、只看"步骤成功"会漏掉真正的问题

这类坑占了本项目的一半以上，共同特征是：**CI 绿 / 测试过 / 但该做的事没做**。

### 1. 冒烟只测"能渲染"，测不出"一用就崩"

- **现象**：源码线的包 TUI 渲染完全正常，一发消息就崩：
  `Missing OpenTUI asset "@opentui/core/parser.worker.js"`
- **为什么漏**：冒烟只断言"主界面渲染出来了"。崩发生在渲染**之后**（用户输入 prompt 才触发解析）。
- **修**：`smoke-release.sh` 现在会**真发一条 prompt 并等回复**（`E2E-OK`）。
- **教训**：**冒烟必须测真实交互**。"能启动"和"能渲染"是最低标准，不是验收标准。

### 2. 步骤报 success，但 `if:` 条件其实没满足

- **现象**：`watch-upstream` 的 dispatch 步骤被跳过，日志里 step 显示 `success`，我还以为触发了。
- **真因**：我在 python 里改 YAML 时 sed 转义多了一层（`\\1` 而不是 `\1`），算术表达式
  `$(( \1 + 1 ))` 直接炸 → `set -e` 中途退出 → **`new=true` 从没写进 `$GITHUB_OUTPUT`**
  → 下游 `if: steps.state.outputs.new == 'true'` 为假 → 静默跳过。
- **修**：改完 YAML 后**逐字检查生成的脚本**；用 `set -euo pipefail` 时，任何一步失败都该让
  整个 step 失败，而不是"半死不活地 success"。
- **教训**：**不要只看 step 的 conclusion，要看它实际产生了什么输出**。
  有条件分支的 workflow，出错时静默跳过 = 没跑。

### 3. 版本号算错 → 覆盖掉已发布的 release

- **现象**：`rev` 取的是"已有修订号的最大值"，应该是"最大 +1"。同版本重跑会
  `--clobber` 掉已经发出去的 release（资产被静默替换）。
- **教训**：**幂等逻辑要写"下一个"，不是"上一个"**。任何"算下一个版本号"的代码，
  都要用"已存在的最大值 + 1"。

### 4. 两条线抢同一个 tag 命名空间

- **现象**：源码线 release 的描述写着"源码构建"，**资产却是镜像线的产物**——
  tag push 触发的镜像线 workflow 用 `--clobber` 把它覆盖了。
- **修**：命名空间分开（源码线 `v<ver>+termux<N>`，镜像线 `v<ver>+mirror<N>`），
  镜像线 workflow 只认 `v*-mirror` tag。
- **教训**：**同一个仓库里多个产线，命名空间必须一开始就分开**。
  而且"描述"和"内容"不一致时，人眼很难发现——要定期核对资产内容而不只是 tag。

---

## 二、版本/ABI 相关的坑

### 5. 原生库与 JS 侧必须同版本

- **现象**：`NativeError: ot_session_get_renderer_state failed: InvalidArgument`
- **原因**：FFI 结构体布局对不上，**静态完全看不出来**，只在运行时炸。
- **修**：`scripts/verify-abi.sh` 在出包前静态比对 `@opentui/core` 的 `nativeSymbols`
  与 `.so` 的导出符号。
- **附带坑**：`grep -oE 'ot_[a-z_]+:'` 会把注释和字符串里的也算进来 → 误报一片。
  要精确取 `nativeSymbols` 对象的键（`scripts/abi-symbols.py`）。

### 6. Zig 的 libc++ 和 NDK 的 libc++ 不能混链

- **现象**：缺 20 个 `std::__1::` 符号（`bad_function_call` 的 vtable/typeinfo 等）。
- **原因**：Zig 自带的 libc++ 用 `std::__1`，NDK 的用 `std::__ndk1`，混链必炸。
- **修**：**分工**——Zig 只出 `.a`（不链接），C++ 交给 NDK clang++，最后静态链 libc++。
- **附带坑**：Zig 0.17 拒绝为 android "provide libc"
  （`unable to provide libc for target …-android.30`），所以 `.so` 不能由 Zig 直接链；
  静态库阶段用 `module.link_libc = false` 绕开。

### 7. bionic 缺 `pthread_tryjoin_np`

- **现象**：`dlopen` 失败：`cannot locate symbol "pthread_tryjoin_np"`。
- **修**：`compat.c` 补一个 6 行的实现。
- **附带坑**：**必须用 `clang` 按 C 编**，用 `clang++` 编会被 name-mangling 成 C++ 符号，白搭。

### 8. opentui 0.8.0/0.8.1 的 build.zig 还是 Zig 0.16 的 API

- **现象**：`.ReleaseFast` / `b.args` / `b.build_root` 在 Zig 0.17 里都不存在了。
- **修**：原生库统一钉 **0.8.2**，并用 `jq` 把 opencode catalog 里的 `@opentui/*` 一起提上去。
- **附带坑**：改完 catalog **必须删 `bun.lock` 重装**，否则 hash 对不上。
- **教训**：这类"上游版本漂移"要有**明确的报错**，而不是让编译器吐一堆看不懂的东西。
  现在 `build-source-deb.sh` 会读 opentui 的 `.zig-version` 并明确报"需要 zig X，本机是 Y"。

---

## 三、环境/工具链的坑

### 9. NDK 的 clang 是 x86_64，Termux 上跑不了

- **事实**：`readelf -h clang-18` → `Machine: Advanced Micro Devices X86-64`。
- **含义**：NDK 只能当"头文件 + 静态库"来源（sysroot 23M + libs 28M），
  **不能**在设备上用它编 C++。
- **设备上可行的替代**：Termux 自带的 clang 配 NDK 的 libc++ 头
  （`-nostdinc++ -isystem <NDK>/usr/include/c++/v1`）——已验证能编出 yoga 的 .o。
- **为什么没做**：手机上要下 680MB NDK、编 40 分钟，而 99% 的用户只会 `dpkg -i`。
  投入产出比不对，详见 [BUILD.md](BUILD.md)。

### 10. `strings f | grep -q` 在 `set -o pipefail` 下会误判失败

- **现象**：明明二进制里有版本号，检查却报"找不到"。
- **原因**：`grep -q` 找到就提前退出 → `strings` 收到 SIGPIPE → 整条管道返回非零 →
  `pipefail` 判定失败。
- **修**：先落盘再匹配（`strings -a f > tmp && grep tmp`）。

### 11. Termux 的 umask 077 会让 `dpkg-deb` 拒收

- **现象**：`dpkg-deb: error: control directory has bad permissions 700`。
- **修**：打包前 `find "$BUILD" -type d -exec chmod 755 {} +`。

### 12. 大文件上 `dpkg-deb --fsys-tarfile | tar -xO | file -` 不稳

- **现象**：`file` 收到空输入 → 报 "empty" → CI 失败。
- **修**：先 `dpkg-deb -x` 解包，再 `file -b`。

### 13. YAML 里的 heredoc 会破坏文件结构

- **现象**：GitHub 报 "Invalid workflow file"，但本地 YAML 解析看着没问题。
- **原因**：块标量 `run: |` 里嵌 `<<EOF`，内容缩进和终止符不对就把 YAML 结构带歪了。
- **修**：改用 `printf` 拼字符串。
- **附带坑**：YAML 内联值后面**不能跟 `# 注释`**（`ZIG_VERSION: '0.16.0'  # xxx` 会让
  整个文件解析失败）。

### 14. bun 1.4 的 isolated 安装布局把包藏在隐藏目录

- **现象**：`node_modules/@opentui/core` 不存在，glob 也抓不到。
- **真因**：包在 `node_modules/.bun/@opentui+core@…/node_modules/@opentui/core`（隐藏目录）。
- **修**：用 `os.walk` 而不是 glob。

---

## 四、上游/流程相关的坑

### 15. `releases/latest` 不等于最新主线版本

- **现象**：`anomalyco/opencode` 的 `/releases/latest` 指向 **v1 维护线**（1.19.5），
  不是 v2 主线（2.2.5）。
- **修**：拉一批 release 自己按 semver 取最大。

### 16. 用 API 建 tag **不会**触发 `push` 事件

- **现象**：想用 Git Data API 建 tag 来触发打包 workflow，结果什么都没发生。
- **修**：改用 `workflow_dispatch`（`gh workflow run`）。

### 17. GitHub 把 author/committer 的时区归一化成 UTC

- **现象**：同样的内容，用 API 重放的 commit **SHA 必然和本地不同**。
- **影响**：不能用 SHA 判断"推没推上去"。
- **修**：`scripts/push-api.sh` 断言的是 **tree 逐字节一致**（那才是内容的标识），
  推送进度记在 `.git/api-push-state`。

### 18. GitHub 会在仓库 60 天无活动时停掉 scheduled workflow

- **含义**：`watch-upstream` 的 cron 不会永远跑。
- **对策**：偶尔提交一下，或者把频率降到 hourly（更容易被察觉失效）。

---

## 五、可以推广的原则

1. **验收标准要覆盖真实使用**。"能启动"不等于"能用"。
   —— 冒烟要发真请求、要落盘核对。
2. **静默跳过比报错更危险**。条件分支失效时一定要有日志。
   —— 检查 outputs 真的写进去了。
3. **版本号是接口**。原生库 / JS / 包版本三者必须对齐，并且**在 CI 里静态校验**。
4. **命名空间一开始就分开**。多产线共用 tag 前缀，迟早互相覆盖。
5. **把"上游会变"当成常态**。钉版本、检测漂移、给出可读的报错。
6. **每个坑都要留下可执行的检查**，而不是只在文档里写"注意别搞错"。
   —— 本项目里 `verify-abi.sh` / `smoke-static.sh` / `e2e-scenarios.sh` 都是这个原则的产物。
