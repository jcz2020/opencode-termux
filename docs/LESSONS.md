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
  镜像线 workflow 只认 `v<ver>+mirror<N>`（触发模式 `'v*\+mirror*'`，GitHub glob 里
  `+` 要转义）。
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

## 五、文档自己也会腐坏

前面四节都是代码和 CI 的坑。这一节是**文档的坑** —— 写文档这件事本身没有 CI 管，
所以它坏得最安静：没人报错，只是读的人被误导。

### 19. 文档里的数字和链接会过期

- **怎么发现的**：重写中文文档时，逐条对着实际产物核了一遍，发现全是错的：
  - README 的安装命令还指着 `termux1`，而最新 release 已经是 `termux2`；
  - 镜像线体积写 88 MB，实际 82 MB；
  - `opencode.real` 写 210 MB，实际 200 MiB；
  - 「跑 8 个真实交互场景」—— 脚本里其实是 6 个交互场景 + 2 项落盘核对。
- **为什么没人发现**：文档没有 CI。每次改完代码就忘了回头改文档，
  或者改了文档但没人拿真实产物对一遍。
- **怎么修**：**改文档时顺手核**：数字用 `dpkg-deb -c` 量，链接用 `curl` 打一下，
  版本号对着 release 列表看。核一遍成本很低，不核就是给下一个人埋雷。
- **教训**：**文档里的每个数字都是一条待验证的断言**。没核过的数字比没有数字更糟 ——
  没有数字读者会自己去查，写错了读者会信。

### 20. 章节编号会乱

- **怎么发现的**：`docs/spike-android-bun.md` 的编号是 1、2、3、4、5、6、6b、7、9、10、11、12，
  然后在**文件最末尾**突然冒出一个「8. 另一个发现」。
  原因是中途插章节时改了编号，末尾那段忘了归位。
- **怎么修**：已经重排成连续的 1…12。
- **教训**：**插入章节时必须重排后面的编号**。或者更省事：干脆不用数字编号，
  用小标题（就像 LESSONS.md 自己的做法）—— 插一节不用改任何别的地方。

### 21. 中文文档写成英文直译的样子

- **怎么发现的**：用户指出文档「像是从英文机翻过来的，看似想往口语化方向发展，
  实际上却生硬得很」。具体表现：
  - 造了个中文里根本不存在的词「**出包**」（该说「编译」「打包」「出 deb」）；
  - `LESSONS.md` 里的条目标签全是英文小标题直译：**现象** / **真因** / **修** / **教训**；
  - 满篇 `→` 箭头链（`取源码 → 编四个件 → 拼 rootfs → dpkg-deb → 自检`），
    读起来像流程图不像人话；
  - 每句都「本项目」，主语换着说会不通顺 —— 这恰恰是中文和英文的差异。
- **为什么难自己发现**：写的时候每句话都「能看懂」，合起来就别扭。
  这是中文母语者才容易察觉的问题。
- **怎么修**：整篇重写。具体手法：
  - 造词先查一遍有没有现成说法（编译 / 打包 / 打包发布，没有「出包」）；
  - 标签改成中文自然的问法：**怎么发现的** / **为什么会漏** / **怎么修** / **教训**；
  - 箭头链只在真表示流水线的地方留，其余该断句就断句；
  - 主语该换就换：「本项目」→「我们」「这条线」。
- **教训**：**中文文档要按中文的语感写，不能按英文的骨架填词**。
  改完自己从头读一遍，读着别扭的地方就是要改的地方。

### 22. 「网络不通」这种结论也会过期

- **怎么发现的**：`AGENTS.md` 里写着「`github.com` **不可用**」，
  当天下午 `git push` 就连上了，一次就推成了。
  而这份文档的上一版也写着「git push 也走不通」，同样是过期的结论。
- **为什么危险**：写「不可用」会让人**永远不再试**，
  于是每次都绕远路走 API 脚本 —— 多一个依赖，还留下 SHA 不一致的烂摊子。
- **怎么修**：改成「**时通时不通**」，并写清策略：
  **先试 `git push`，报错了才退回 API 脚本**；走 API 之后如果 push 通了，
  先 `git fetch` 核对 tree 一致，再 `git push --force` 把 SHA 对齐。
- **教训**：**写「某东西不可用/不支持」之前，先确认它是真的稳定如此**。
  「我这台机器上次不行」和「它就是不行」是两回事，文档要写后者，
  不然读者会照着一条过期的结论一直绕路。

### 23. 旧版构建发布抢占 GitHub Latest Release

- **怎么发现的**：`2.2.6+termux1` 发布后，下午有人手动跑了一次 `2.2.5` 的构建（`2.2.5+termux3`），
  GitHub 的 Release 页面和 API 立刻把 2.2.5 标成了 **Latest**！
  更严重的是，`opencode-app` 的运行时安装器也是根据 `releases/latest/download/runtime-manifest.json` 下载的，
  结果所有用户的 App 都被回退成了旧版。
- **真因**：GitHub 默认根据 `published_at`（发布时间戳）决定谁是 `Latest`，根本不懂 SemVer。
  后发布的旧版本时间戳更新，直接挤掉了先发布的更高版本。
- **怎么修**：
  1. 线上用 `gh release edit v2.2.6+termux1 --latest` 纠正当前状态；
  2. CI 工作流（`build-deb-source.yml`）发布前比对已发版本号，若版本号 `<` 最高已发版本，
     默认阻断；必须显式传 `allow_downgrade=true` 才能构建，且发布时强制带 `--latest=false`。
- **教训**：**不能把时间先后当成版本大小**。自动发布脚本必须显式管理 `--latest` 标志，
  防守旧分支或手工补发把线上 Latest 标乱。

### 24. 官方更新器会破坏 Termux 环境，且镜像断点续传有 504 陷阱

- **怎么发现的**：用户执行官方 `opencode update` 时，官方试图运行 `curl https://opencode.ai/v2/install`，
  下载 x86/glibc 二进制覆盖掉现有的 bionic 环境。另外，用 `ghfast.top` 等镜像下载 90 MB deb 时，
  若中途断开带 `Range` 续传，经常遇到 504 Gateway Timeout 或返回 HTML 防爬验证页。
- **怎么修**：
  1. **双重拦截**：wrapper 层拦截 `update|upgrade` 直接转到 Termux 专属更新器；
     同时在源码中将更新检查与更新动作打补丁对齐到本项目的 GitHub Release；
  2. **下载防御**：下载大文件时检查首 8 字节是否为 `!<arch>\n`，若为 HTML 验证页立即清除；
     镜像续传失败时自动回退到 GitHub Release Asset API 签名直链并全新重试。
- **教训**：**第三方镜像只能做传输加速，绝不能当成可信源**。SHA-256 校验和格式探测是底线。

### 25. 2.3.0 改为后台服务后，wrapper 不能再经过 linker64

- **怎么发现的**：2.3.0 把 TUI 和 HTTP 服务拆开，TUI 发现没有可用服务时，
  用 `process.execPath` 重新执行 `serve --service`。wrapper 如果最后是
  `exec /system/bin/linker64 "$P/bin/opencode.real"`，Bun 会把
  `process.execPath` 报成 `/system/bin/linker64`，拼出的命令变成
  `linker64 serve --service`，链接器立即报 `error: expected absolute path: "serve"`。
- **后果**：服务永远起不来，TUI 重试会刷出上千条失败；`opencode --version`
  仍然正常，所以只看版本号完全发现不了。
- **怎么修**：
  1. wrapper 直接 `exec "$P/bin/opencode.real" "$@"`，让 Bun 拿到真实路径；
  2. `smoke-static.sh` 拒绝含 `linker64` 的 wrapper，并检查最后一条 `exec`
     是 `opencode.real`；
  3. 新增 `scripts/smoke-service.sh`：用隔离的 `XDG_STATE_HOME` + 随机端口
     真正执行 `opencode service start/status/stop`，接入 `make smoke` 与
     `smoke-release.sh`；
  4. 安装与冒烟分开执行，避免 `dpkg -i` 替换掉正在运行的后台服务。
- **教训**：**`process.execPath` 是 2.3.0 的接口**。涉及 wrapper/启动器的改动，
  不能只验 `--version`，必须验“后台服务能不能被自己拉起来”。

### 26. 2.3.0 的持久 PTY：缺二进制 + socket 目录不可写

- **怎么发现的**：日志刷屏：
  ```text
  process daemon unavailable; spawning shell command instead
  Executable not found in $PATH: "opencode-pty"
  ```
  说明 agent shell 退化成了普通管道。
- **两个叠加原因**：
  1. runtime 里没有 `opencode-pty`；
  2. 即使补上，daemon 默认把 Unix socket 放到 `/tmp`，Android 上不可写；
     路径过长还会触发 `SUN_LEN`。
- **怎么修**：
  1. 用 `scripts/opencode-pty.lock` 固定
     `@opencode/pty-linux-arm64-musl` 0.5.2（静态 aarch64 musl，协议 8）；
  2. `fetch-opencode-pty.sh` 取二进制，装到 `bin/opencode-pty` 并确保 755；
  3. wrapper 注入 `OPENCODE_PTY_BIN`；
  4. wrapper 注入短的 `OPENCODE_PTY_SOCKET_DIR=${TMPDIR:-$P/tmp}/opty`；
  5. `build-source-deb.sh` 核对上游 `@opencode/pty` 版本与 lock 一致；
  6. `make smoke-pty` 真正启动/停止 daemon。
- **附带踩坑**：`termux4` 构建时 rootfs 统一 `chmod 644` 把 `opencode-pty`
  的执行位刷掉了，`smoke-static` 现在会检查执行位；`termux5` 修复。
- **教训**：**“二进制存在”不等于“PTY 能用”**。这个功能同时依赖
  可执行位、正确版本、可写且足够短的 socket 路径。

### 27. Termux 会删旧 deb，工具链必须锁版本 + 做缓存

- **怎么发现的**：准备加 `gh` 时，之前候选的 `2.103.3` 已经从 Termux pool
  消失（404），索引里只剩 `2.104.0`。锁了旧路径的构建会直接失败。
- **后果**：只有当前构建失败，已发布产物不受影响；但历史 tag 无法重建。
- **怎么修**：
  1. `scripts/termux-tools.lock` 固定所有工具的版本、路径、sha256；
  2. `watch-tools` 每天对比 Termux 索引，只维护一个 issue，不自动发版；
  3. `publish-tool-cache` 把一次 lock 对应的全部 deb 打成
     `termux-tools-<lock-sha>.tar.zst`，上传到独立的 `toolchain-cache` release；
  4. `bundle-termux-tools.sh` 的下载顺序：本地 cache → toolchain-cache → Termux 源；
  5. 缓存约 22 MB/快照，不进入 Git，不影响 runtime bundle/APK。
- **教训**：**pin 之后还要有“发现更新”和“保住旧包”两条腿**。
  只 pin 不巡检会错过更新；只巡检不缓存会在上游删包时无法重建。

### 28. Android 上的文件监听（watcher）：FUSE 陷阱、递归快照轮询与 EACCES 噪音收敛

- **怎么发现的**：App 实例消费 `2.3.0+termux5` 后，工作区默认在 `/storage/emulated/0/OpenCode`：
  1. 外部编辑器修改文件后 WebUI 不自动刷新；
  2. 冷启动日志刷屏 `watcher backend not supported ... platform=android`（约 6 次）；
  3. 伴随 `failed to watch directory: EACCES ... watch '/'、watch '/storage'`；
  4. 触摸 / 修改工作区文件未观察到任何文件监听事件。
- **根因分析**：
  1. 上游 directory watcher 依赖 `@parcel/watcher`，构建期因缺少 Android 预编译 binding 降级为抛错，导致所有目录级监听（`.config/opencode`、`.opencode`、`skill/`、`skills/`）全部失效并退化关闭；
  2. Android 外部存储 `/storage/emulated/0` 是 FUSE 挂载点，跨应用 UID 写入或原子重命名保存时，inotify 事件极易丢失；
  3. `ConfigDiscovery.discover` 盲目使用 `fs.up` 向上查找祖先目录，一路爬到 `/`、`/storage`、`/etc`，并在 `ConfigWatch.plan` 中注册父级 entries 监听，触发无权限报错 `EACCES`；
  4. `LocationWatcher` 原先仅监听 `.git/HEAD`，未对工作区目录建立递归监听，外部新建/改动无法推入 `FileSystem.Event.Changed`。
- **怎么修**：
  1. **实现基于递归快照的 `subscribePolling` 目录监听**：递归收集 mtime/ctime/size 快照做 diff，自动过滤 `.git`、`node_modules` 等 ignore 路径，对缺失目录优雅等待；在 Android 下默认使用 polling，同时保留 `OPENCODE_WATCHER=polling` 显式开关与 `OPENCODE_DISABLE_FILEWATCHER=1` 全局禁用；
  2. **祖先边界收敛与 EACCES 抑制**：定义系统根黑名单（`/`、`/storage`、`/storage/emulated`、`/storage/emulated/0`、`/data`、`/etc` 等，外加 `$HOME` 的祖先），`discovery.ts` 与 `watch.ts` 不再向其爬取/订阅；`watcher.ts` 拦截黑名单目录，EACCES/EPERM 降级为 debug 且只记一次；
  3. **工作区事件透传**：`LocationWatcher` 订阅 `location.directory` 目录级变更，将新增/修改/删除发布为 `FileSystem.Event.Changed`，通过 SSE `/api/event` 驱动 WebUI 实时刷新；
  4. **新增冒烟**：`scripts/smoke-watcher.sh`（真机服务 + SSE 事件捕获 + 配置热重载）与 `make smoke-watcher`。
- **termux6 的二次踩坑（值得单独记）**：第一版补丁里两处 API 用错，静态检查和「工作区能出事件」都发现不了：
  1. `FSUtil.globMatch` 只是 **Service 实例字段**，命名空间上没有这个静态函数，调用直接抛 `TypeError`。config 目录带 ignore 列表，扫描到第一个文件就抛，轮询每轮都中断 → 配置热重载静默失效；工作区 `ignore=[]` 才碰巧正常。
  2. `Glob.match` 的签名是 `(pattern, filepath)`，实参写反了不会报错，只会静默不匹配。
  修法：改用 `Glob.match(pattern, rel)`；起始快照与每轮扫描都包 `try/catch`，任何扫描异常都不能让监听静默死掉；补丁抽成 `spike/opencode-android/patch-watcher.py` 并配 `test-patch-watcher.py`（片段断言 + 真实目录行为单测），接进 `build.sh` 做门禁。
- **termux7 的真机结论**：`/storage/emulated/0/OpenCode` 下增/改/删/子目录/空目录/重命名全部能收到 `filesystem.changed`，配置目录新增 agent 可热重载，冷启动 `backend not supported` 与 `EACCES` 均为 0。
- **教训**：**Android 移动端文件系统不能假设 POSIX/inotify 语义完整**。FUSE 挂载点上的跨进程文件监控必须优先保证 Polling 递归快照兜底，且必须严格限制祖先遍历边界。更要紧的是：**「能出事件」不能证明「所有监听都活着」**——带 ignore 的订阅路径要单独验证。

---

## 六、可以推广的几条

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
7. **文档也是代码，也要 review。** 数字要对着产物核，链接要打得通，
   结论要重新验证（见第五节）。文档腐坏不会让 CI 变红，只会让人做错决定。
8. **写中文就按中文写。** 不要造词，不要拿英文骨架直接填词，
   写完自己读一遍 —— 读着别扭就是要改（见第 21 条）。
9. **别把「我这儿不行」写成「它就是不行」。** 环境的结论会过期，
   文档要写成「时通时不通 + 该怎么兜底」，而不是一句「不可用」。
10. **`--version` 不是验收。** 运行时接口一变（2.3.0 的后台服务、持久 PTY），
    版本号照样能打印，真正要测的是服务拉起、socket 路径、真实 shell 链路。
