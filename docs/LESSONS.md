# 经验教训

> 这个项目踩过的坑，按类型分了一下类。
> 每条都注明**当时是怎么发现的** —— 有好几条都属于「表面全绿、实际没生效」，
> 那种坑最难查。

---

## 一、「步骤显示成功」不等于「事情做成了」

这类坑占了本项目一半以上，共同点是：**CI 绿的、测试也过，但该做的事压根没发生。**

### 1. 冒烟只测「能渲染」，测不出「一用就崩」

- **怎么发现的**：源码线的包 TUI 渲染完全正常，一发消息就崩：
  `Missing OpenTUI asset "@opentui/core/parser.worker.js"`
- **为什么会漏**：冒烟只断言「主界面渲染出来了」。崩溃发生在渲染**之后** ——
  用户输入 prompt 才会触发解析。
- **怎么修**：`smoke-release.sh` 现在会**真发一条 prompt 并等回复**（`E2E-OK`）。
- **教训**：**冒烟必须测真实交互**。「能启动」和「能渲染」只是底线，不是验收标准。

### 2. step 报 success，但 `if:` 条件其实没满足

- **怎么发现的**：`watch-upstream` 的 dispatch 步骤被跳过，日志里 step 显示 `success`，
  我还以为触发了。
- **真正的原因**：我在 Python 里改 YAML 时 sed 转义多了一层（`\\1` 而不是 `\1`），
  算术表达式 `$(( \1 + 1 ))` 直接炸，`set -e` 中途退出，
  **`new=true` 从没写进 `$GITHUB_OUTPUT`**，
  下游 `if: steps.state.outputs.new == 'true'` 判假，于是静默跳过。
- **怎么修**：改完 YAML 要**逐字检查生成的脚本**；用 `set -euo pipefail` 时，
  任何一步失败都应该让整个 step 失败，而不是半死不活地报 success。
- **教训**：**不要只看 step 的 conclusion，要看它实际产生了什么输出**。
  带条件分支的 workflow 一旦出错就静默跳过，等于没跑。

### 3. 版本号算错，覆盖掉了已经发布的 release

- **怎么发现的**：`rev` 取的是「已有修订号的最大值」，应该是「最大 +1」。
  同一个版本重跑会 `--clobber` 掉已经发出去的 release，资产被悄悄换掉。
- **教训**：**算「下一个」要用「已有的最大 +1」，不是「已有的最大」**。
  凡是涉及「算下一个版本号」的代码，这一条都得盯死。

### 4. 两条线抢同一个 tag 命名空间

- **怎么发现的**：源码线 release 的描述写着「源码构建」，**资产却是镜像线的产物** ——
  tag push 触发的镜像线 workflow 用 `--clobber` 给覆盖了。
- **怎么修**：命名空间分开（源码线 `v<ver>+termux<N>`，镜像线 `v<ver>+mirror<N>`），
  镜像线 workflow 只认 `v*-mirror` tag。
- **教训**：**同一个仓库里有多条产线，命名空间必须一开始就分开**。
  另外，「描述」和「内容」不一致时人眼很难发现 —— 得定期核对资产内容，不能只看 tag。

---

## 二、版本和 ABI

### 5. 原生库和 JS 侧必须同版本

- **怎么发现的**：`NativeError: ot_session_get_renderer_state failed: InvalidArgument`
- **原因**：FFI 的结构体布局对不上，**静态完全看不出来**，只有运行时才炸。
- **怎么修**：`scripts/verify-abi.sh` 在打包前静态比对 `@opentui/core` 的 `nativeSymbols`
  和 `.so` 导出的符号。
- **顺带一个坑**：`grep -oE 'ot_[a-z_]+:'` 会把注释和字符串里的也匹配进来，误报一片。
  要精确取 `nativeSymbols` 对象的键（见 `scripts/abi-symbols.py`）。

### 6. Zig 的 libc++ 和 NDK 的 libc++ 不能混着链

- **怎么发现的**：缺 20 个 `std::__1::` 符号（`bad_function_call` 的 vtable/typeinfo 等）。
- **原因**：Zig 自带的 libc++ 用 `std::__1`，NDK 的用 `std::__ndk1`，混链必炸。
- **怎么修**：**分工** —— Zig 只出 `.a`（不链接），C++ 交给 NDK clang++，最后静态链 libc++。
- **顺带一个坑**：Zig 0.17 拒绝给 android target「提供 libc」
  （`unable to provide libc for target …-android.30`），所以 `.so` 不能由 Zig 直接链；
  编静态库那一步用 `module.link_libc = false` 绕过去。

### 7. bionic 没有 `pthread_tryjoin_np`

- **怎么发现的**：`dlopen` 失败：`cannot locate symbol "pthread_tryjoin_np"`。
- **怎么修**：`compat.c` 补一个 6 行的实现。
- **顺带一个坑**：**必须用 `clang` 按 C 编**，用 `clang++` 编会被 mangle 成 C++ 符号，白搭。

### 8. opentui 0.8.0/0.8.1 的 build.zig 还是 Zig 0.16 的 API

- **怎么发现的**：`.ReleaseFast` / `b.args` / `b.build_root` 在 Zig 0.17 里都不存在了。
- **怎么修**：原生库统一固定在 **0.8.2**，并用 `jq` 把 opencode catalog 里的 `@opentui/*` 一起提上去。
- **顺带一个坑**：改完 catalog **必须删掉 `bun.lock` 重装**，否则 hash 对不上。
- **教训**：这类「上游版本漂移」要给出**明确的报错**，而不是让编译器吐一堆看不懂的东西。
  现在 `build-source-deb.sh` 会读 opentui 的 `.zig-version`，直接报「需要 zig X，本机是 Y」。

---

## 三、环境和工具链

### 9. NDK 的 clang 是 x86_64，Termux 上跑不了

- **怎么发现的**：`readelf -h clang-18` 显示 `Machine: Advanced Micro Devices X86-64`。
- **意味着什么**：NDK 只能当「头文件 + 静态库」的来源（sysroot 23M + libs 28M），
  **不能**在设备上用它编 C++。
- **设备上可行的替代**：用 Termux 自带的 clang 配 NDK 的 libc++ 头
  （`-nostdinc++ -isystem <NDK>/usr/include/c++/v1`）—— 已经验证能编出 yoga 的 .o。
- **为什么没做**：手机上要下 680MB 的 NDK、编 40 分钟，而 99% 的用户只会 `dpkg -i`。
  投入产出不划算，详见 [BUILD.md](BUILD.md)。

### 10. `strings f | grep -q` 在 `set -o pipefail` 下会误判失败

- **怎么发现的**：二进制里明明有版本号，检查却报「找不到」。
- **原因**：`grep -q` 一找到就提前退出，`strings` 收到 SIGPIPE，整条管道返回非零，
  `pipefail` 判定失败。
- **怎么修**：先落盘再匹配（`strings -a f > tmp && grep tmp`）。

### 11. Termux 的 umask 077 会让 `dpkg-deb` 拒收

- **怎么发现的**：`dpkg-deb: error: control directory has bad permissions 700`。
- **怎么修**：打包前 `find "$BUILD" -type d -exec chmod 755 {} +`。

### 12. 大文件上 `dpkg-deb --fsys-tarfile | tar -xO | file -` 不稳

- **怎么发现的**：`file` 收到空输入，报 "empty"，CI 失败。
- **怎么修**：先 `dpkg-deb -x` 解包，再 `file -b`。

### 13. YAML 里的 heredoc 会破坏文件结构

- **怎么发现的**：GitHub 报 "Invalid workflow file"，但本地 YAML 解析看着没问题。
- **原因**：块标量 `run: |` 里嵌了 `<<EOF`，内容和终止符的缩进不对，把 YAML 结构带歪了。
- **怎么修**：改用 `printf` 拼字符串。
- **顺带一个坑**：YAML 内联值后面**不能跟 `# 注释`**（`ZIG_VERSION: '0.16.0'  # xxx` 会让
  整个文件解析失败）。

### 14. bun 1.4 的 isolated 安装布局把包藏在隐藏目录里

- **怎么发现的**：`node_modules/@opentui/core` 不存在，glob 也抓不到。
- **真正的原因**：包在 `node_modules/.bun/@opentui+core@…/node_modules/@opentui/core`（隐藏目录）。
- **怎么修**：用 `os.walk`，不要用 glob。

---

## 四、上游和流程

### 15. `releases/latest` 不等于最新主线版本

- **怎么发现的**：`anomalyco/opencode` 的 `/releases/latest` 指向 **v1 维护线**（1.19.5），
  不是 v2 主线（2.2.5）。
- **怎么修**：拉一批 release 下来自己按 semver 取最大。

### 16. 用 API 建 tag **不会**触发 `push` 事件

- **怎么发现的**：想用 Git Data API 建 tag 来触发打包 workflow，结果什么都没发生。
- **怎么修**：改用 `workflow_dispatch`（`gh workflow run`）。

### 17. GitHub 把 author/committer 的时区归一化成 UTC

- **怎么发现的**：同样的内容，用 API 重放的 commit **SHA 必然和本地不同**。
- **这意味着**：不能用 SHA 判断「推没推上去」。
- **怎么修**：`scripts/push-api.sh` 断言的是 **tree 逐字节一致**（那才是内容的标识），
  推送进度记在 `.git/api-push-state`。

### 18. 仓库 60 天没活动，GitHub 会停掉 scheduled workflow

- **这意味着**：`watch-upstream` 的 cron 不会永远跑。
- **对策**：偶尔提交一下，或者把频率降到 hourly（更容易察觉它其实没在跑）。

---

## 五、可以推广的几条

1. **验收标准要覆盖真实使用。**「能启动」不等于「能用」。
   冒烟要发真请求、要落盘核对。
2. **静默跳过比直接报错更危险。** 条件分支失效时一定要留日志，
   并且检查 outputs 真的写进去了。
3. **版本号就是接口。** 原生库、JS、包这三者的版本必须对齐，
   并且**在 CI 里做静态校验**。
4. **命名空间一开始就分开。** 多条产线共用 tag 前缀，迟早互相覆盖。
5. **把「上游会变」当成常态。** 锁版本、检测漂移、给出人能看懂的报错。
6. **每个坑都要留下一个能跑的检查**，而不是只在文档里写一句「注意别搞错」。
   本项目里的 `verify-abi.sh` / `smoke-static.sh` / `e2e-scenarios.sh` 都是这么来的。
