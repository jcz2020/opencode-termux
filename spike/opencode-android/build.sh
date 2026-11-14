#!/usr/bin/env bash
# build.sh — 用官方 android bun 把 opencode 源码编成 aarch64 bionic 二进制。
#
# 用法：build.sh <opencode-src> <libopentui.so> <librust_pty.so> [bun-release=bun-v1.4.4]
#
# 做的事：
#   1. 给 packages/cli/script/build.ts 打 android target 补丁（4 处）
#   2. 给 node_modules/@opentui/core 打 android 资产描述补丁（1 处）
#   3. bun build --compile --target=bun-linux-aarch64-android
set -euo pipefail

SRC="${1:?opencode source dir}"
LIBOPENTUI="${2:?libopentui.so (bionic)}"
LIBPTY="${3:?librust_pty.so (bionic)}"
RELEASE="${4:-bun-v1.4.4}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$SRC"

echo "==> 1/3 补丁 packages/cli/script/build.ts"
python3 - packages/cli/script/build.ts <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
if "android-arm64" in s:
    print("   already patched"); sys.exit(0)

# (a) 目标表加 android
old = """  { os: "win32", arch: "x64", avx2: false },
]"""
new = """  { os: "win32", arch: "x64", avx2: false },
  { os: "android", arch: "arm64" },
]"""
assert old in s, "allTargets anchor"
s = s.replace(old, new, 1)

# (b) bun 资产名：android 走 linux 平台 + android abi（bun-linux-aarch64-android.zip）
old = """  const platform = item.os === "win32" ? "windows" : item.os"""
new = """  const platform = item.os === "win32" ? "windows" : item.os === "android" ? "linux" : item.os"""
assert old in s, "platform anchor"
s = s.replace(old, new, 1)

old = """    item.abi,
    item.avx2 === false ? "baseline" : undefined,
  ]"""
new = """    item.os === "android" ? "android" : item.abi,
    item.avx2 === false ? "baseline" : undefined,
  ]"""
assert old in s, "asset name anchor"
s = s.replace(old, new, 1)

# (c) 编译目标名：bun-android-arm64 不是合法 target，映射成 bun-linux-aarch64-android
old = """      target: target.replace(binary, "bun") as Bun.Build.CompileTarget,"""
new = """      target: compileTarget(item) as Bun.Build.CompileTarget,"""
assert old in s, "compile target anchor"
s = s.replace(old, new, 1)

old = """function targetName(item: (typeof allTargets)[number]) {"""
new = """function compileTarget(item: (typeof allTargets)[number]) {
  // bun 的 android 目标叫 bun-linux-aarch64-android（不是 bun-android-arm64）
  if (item.os === "android") return item.arch === "arm64" ? "bun-linux-aarch64-android" : "bun-linux-x64-android"
  return targetName(item).replace(binary, "bun")
}

function targetName(item: (typeof allTargets)[number]) {"""
assert old in s, "targetName anchor"
s = s.replace(old, new, 1)

# (d) parcel watcher：android 没有预编译 binding，降级成"不可用"
old = """        contents: `export default () => require(${JSON.stringify(parcelWatcherPackage)})`,"""
new = """        contents:
          item.os === "android"
            ? `export default () => { throw new Error("parcel watcher is not available on android") }`
            : `export default () => require(${JSON.stringify(parcelWatcherPackage)})`,"""
assert old in s, "watcher anchor"
s = s.replace(old, new, 1)

p.write_text(s)
print("   patched build.ts")
PY

echo "==> 1.5/3 补丁 packages/cli/src/services/updater.ts（重定向更新检测与升级命令到本项目）"
python3 - <<'PY'
import pathlib, sys
p = pathlib.Path("packages/cli/src/services/updater.ts")
if not p.exists():
    print("   updater.ts not found, skipping patch")
    sys.exit(0)

s = p.read_text()
if "OpenCode-Termux" in s:
    print("   already patched updater.ts")
    sys.exit(0)

# (a) method() 增加 android / termux 检测，映射为 "curl"
old_m = "  const method = Effect.fnUntraced(function* () {\n    if (executable === curlBinary) return \"curl\""
new_m = ("  const method = Effect.fnUntraced(function* () {\n"
         "    if (process.platform === \"android\" || executable.includes(\"/com.termux/\")) return \"curl\"\n"
         "    if (executable === curlBinary) return \"curl\"")
if old_m in s:
    s = s.replace(old_m, new_m, 1)

# (b) release() 重定向到本项目 GitHub Release，只认我们发布的新包
old_r = "  const release = Effect.fnUntraced(function* (method?: Method) {\n    const distribution = method === \"brew\" ? \"homebrew\" : \"npm\""
new_r = ("  const release = Effect.fnUntraced(function* (method?: Method) {\n"
         "    if (process.platform === \"android\" || executable.includes(\"/com.termux/\")) {\n"
         "      const response = yield* Effect.tryPromise({\n"
         "        try: (signal) =>\n"
         "          fetch(\"https://api.github.com/repos/jcz2020/opencode-termux/releases/latest\", {\n"
         "            headers: { Accept: \"application/vnd.github.v3+json\", \"User-Agent\": \"OpenCode-Termux\" },\n"
         "            signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),\n"
         "          }),\n"
         "        catch: (cause) =>\n"
         "          new UpgradeError(\n"
         "            {\n"
         "              title: \"Could not check for OpenCode updates\",\n"
         "              detail: errorDetail(cause),\n"
         "              retry: \"Check your network, then run opencode update again.\",\n"
         "            },\n"
         "            { cause },\n"
         "          ),\n"
         "      })\n"
         "      if (!response.ok)\n"
         "        return yield* Effect.fail(\n"
         "          new UpgradeError({\n"
         "            title: \"Could not check for OpenCode updates\",\n"
         "            detail: `The update service returned HTTP ${response.status}.`,\n"
         "            retry: \"Try again in a few minutes.\",\n"
         "          }),\n"
         "        )\n"
         "      const data: any = yield* Effect.tryPromise({\n"
         "        try: () => response.json(),\n"
         "        catch: (cause) =>\n"
         "          new UpgradeError(\n"
         "            {\n"
         "              title: \"Could not read OpenCode update information\",\n"
         "              detail: errorDetail(cause),\n"
         "              retry: \"Try again in a few minutes.\",\n"
         "            },\n"
         "            { cause },\n"
         "          ),\n"
         "      })\n"
         "      const tag = String(data?.tag_name || \"\")\n"
         "      const v = tag.replace(/^v/, \"\").replace(/\\+termux[0-9]+$/, \"\")\n"
         "      if (!v)\n"
         "        return yield* Effect.fail(\n"
         "          new UpgradeError({\n"
         "            title: \"Could not read OpenCode update information\",\n"
         "            detail: \"No release tag found in repository.\",\n"
         "            retry: \"Try again in a few minutes.\",\n"
         "          }),\n"
         "        )\n"
         "      return { package: \"opencode\", version: v }\n"
         "    }\n"
         "    const distribution = method === \"brew\" ? \"homebrew\" : \"npm\"")
if old_r in s:
    s = s.replace(old_r, new_r, 1)

# (c) upgrade() 执行本项目专属更新脚本
old_u = "        if (method === \"curl\") {\n          const bash = yield* installerBash()"
new_u = ("        if (method === \"curl\") {\n"
         "          if (process.platform === \"android\" || executable.includes(\"/com.termux/\")) {\n"
         "            const updater = path.resolve(path.dirname(executable), \"..\", \"lib\", \"opencode\", \"opencode-updater.sh\")\n"
         "            return yield* runUpgrade({\n"
         "              method,\n"
         "              command: [\"bash\", updater],\n"
         "              displayCommand: [\"opencode\", \"update\"],\n"
         "              title: \"OpenCode update failed\",\n"
         "            })\n"
         "          }\n"
         "          const bash = yield* installerBash()")
if old_u in s:
    s = s.replace(old_u, new_u, 1)

p.write_text(s)
print("   patched updater.ts")
PY

echo "==> 1.6/3 补丁 Android 文件监听与祖先目录收敛（watcher / discovery / watch / location-watcher）"
python3 - <<'PY'
import pathlib, sys

# (a) packages/core/src/config/discovery.ts
discovery_path = pathlib.Path("packages/core/src/config/discovery.ts")
if discovery_path.exists():
    s = discovery_path.read_text()
    if 'platform === "android"' not in s:
        old_sys = '  if (platform === "win32") return AbsolutePath.make(path.join(env.ProgramData || "C:\\\\ProgramData", "opencode"))\n  return AbsolutePath.make("/etc/opencode")'
        new_sys = ('  if (platform === "win32") return AbsolutePath.make(path.join(env.ProgramData || "C:\\\\ProgramData", "opencode"))\n'
                   '  if (platform === "android") {\n'
                   '    const prefix = env.PREFIX || "/data/data/com.termux/files/usr"\n'
                   '    return AbsolutePath.make(path.join(prefix, "etc", "opencode"))\n'
                   '  }\n'
                   '  return AbsolutePath.make("/etc/opencode")')
        if old_sys in s:
            s = s.replace(old_sys, new_sys, 1)

        old_up = '      : yield* fs.up({ targets: ["."], start: location.directory }).pipe(Effect.orDie)'
        new_up = ('      : (yield* fs.up({ targets: ["."], start: location.directory }).pipe(Effect.orDie))\n'
                  '          .filter((d) => !new Set(["/", "/storage", "/storage/emulated", "/data", "/data/data", "/etc", "/system"]).has(d))')
        if old_up in s:
            s = s.replace(old_up, new_up, 1)

        discovery_path.write_text(s)
        print("   patched discovery.ts")
    else:
        print("   already patched discovery.ts")

# (b) packages/core/src/config/watch.ts
watch_path = pathlib.Path("packages/core/src/config/watch.ts")
if watch_path.exists():
    s = watch_path.read_text()
    if "FORBIDDEN_ANCESTORS" not in s:
        old_parents = """  // Keep a parent watch for each root so deletion/recreation is observable.
  const parents = Map.groupBy(
    files.filter((file) => !directories.some((directory) => file !== directory && FSUtil.contains(directory, file))),
    (file) => path.dirname(file),
  )"""
        new_parents = """  // Keep a parent watch for each root so deletion/recreation is observable.
  const FORBIDDEN_ANCESTORS = new Set(["/", "/storage", "/storage/emulated", "/data", "/data/data", "/etc", "/system"])
  const parents = Map.groupBy(
    files.filter((file) => {
      const parent = path.dirname(file)
      if (FORBIDDEN_ANCESTORS.has(parent)) return false
      return !directories.some((directory) => file !== directory && FSUtil.contains(directory, file))
    }),
    (file) => path.dirname(file),
  )"""
        if old_parents in s:
            s = s.replace(old_parents, new_parents, 1)
            watch_path.write_text(s)
            print("   patched watch.ts")
    else:
        print("   already patched watch.ts")

# (c) packages/core/src/filesystem/location-watcher.ts
loc_path = pathlib.Path("packages/core/src/filesystem/location-watcher.ts")
if loc_path.exists():
    s = loc_path.read_text()
    if "reconcileWorkspace" not in s:
        old_active = "    let active: { path: string; scope: Scope.Closeable } | undefined"
        new_active = ("    let active: { path: string; scope: Scope.Closeable } | undefined\n"
                      "    let activeWorkspace: { scope: Scope.Closeable; ignore: string } | undefined\n"
                      "    const reconcileWorkspace = () =>\n"
                      "      lock.withPermit(\n"
                      "        Effect.gen(function* () {\n"
                      "          if (stopped) return\n"
                      "          const ignoreList = policy.current()\n"
                      "          const ignoreKey = JSON.stringify(ignoreList)\n"
                      "          if (activeWorkspace && activeWorkspace.ignore === ignoreKey) return\n"
                      "          if (activeWorkspace) yield* Scope.close(activeWorkspace.scope, Exit.void)\n"
                      "          activeWorkspace = undefined\n"
                      "          const scope = yield* Scope.make()\n"
                      "          activeWorkspace = { scope, ignore: ignoreKey }\n"
                      "          yield* Effect.gen(function* () {\n"
                      "            const updates = yield* watcher.subscribe({\n"
                      "              path: location.directory,\n"
                      "              type: \"directory\",\n"
                      "              ignore: ignoreList,\n"
                      "            })\n"
                      "            yield* Stream.runForEach(updates, publish)\n"
                      "          }).pipe(\n"
                      "            Effect.catchCauseIf(\n"
                      "              (cause) => !Cause.hasInterrupts(cause),\n"
                      "              (cause) => Effect.logError(\"workspace watcher subscription failed\", { directory: location.directory, cause }),\n"
                      "            ),\n"
                      "            Effect.forkIn(scope, { startImmediately: true }),\n"
                      "          )\n"
                      "        }).pipe(Effect.withSpan(\"LocationWatcher.reconcileWorkspace\", { attributes: { directory: location.directory } })),\n"
                      "      )")
        if old_active in s:
            s = s.replace(old_active, new_active, 1)

        old_final = """    yield* Effect.addFinalizer(() =>
      lock.withPermit(
        Effect.gen(function* () {
          stopped = true
          if (active) yield* Scope.close(active.scope, Exit.void)
          active = undefined
        }),
      ),
    )
    yield* policy.observe(reconcile)
    yield* Effect.gen(function* () {
      yield* Plugin.awaitActivation
      yield* reconcile()
    }).pipe("""

        new_final = """    yield* Effect.addFinalizer(() =>
      lock.withPermit(
        Effect.gen(function* () {
          stopped = true
          if (active) yield* Scope.close(active.scope, Exit.void)
          active = undefined
          if (activeWorkspace) yield* Scope.close(activeWorkspace.scope, Exit.void)
          activeWorkspace = undefined
        }),
      ),
    )
    yield* policy.observe(() => Effect.all([reconcile(), reconcileWorkspace()], { discard: true }))
    yield* Effect.gen(function* () {
      yield* Plugin.awaitActivation
      yield* reconcile()
      yield* reconcileWorkspace()
    }).pipe("""

        if old_final in s:
            s = s.replace(old_final, new_final, 1)
            loc_path.write_text(s)
            print("   patched location-watcher.ts")
    else:
        print("   already patched location-watcher.ts")

# (d) packages/core/src/filesystem/watcher.ts
watcher_file = pathlib.Path("packages/core/src/filesystem/watcher.ts")
if watcher_file.exists():
    s = watcher_file.read_text()
    if "subscribePolling" not in s:
        anchor_imports = 'import loadBinding from "./watcher-binding.js"'
        helper_code = '''import loadBinding from "./watcher-binding.js"
import fs from "node:fs"

const FORBIDDEN_ANCESTORS = new Set(["/", "/storage", "/storage/emulated", "/data", "/data/data", "/etc", "/system"])
const reportedEaccess = new Set<string>()

function subscribePolling(
  directory: string,
  ignore: readonly string[],
  publish: (update: Update) => void,
): Effect.Effect<Subscription | undefined> {
  if (FORBIDDEN_ANCESTORS.has(directory)) {
    return Effect.undefined
  }
  const pollInterval = parseInt(process.env.OPENCODE_WATCHER_POLL_INTERVAL || "1000", 10)
  const ignoreList = [...ignore]

  function isIgnored(targetPath: string): boolean {
    const rel = path.relative(directory, targetPath).replace(/\\\\/g, "/")
    if (!rel || rel === ".") return false
    const parts = rel.split("/")
    for (const part of parts) {
      if (FSUtil.ignoredDirectories.includes(part)) return true
    }
    for (const pattern of ignoreList) {
      if (FSUtil.globMatch(rel, pattern) || FSUtil.globMatch(`/${rel}`, pattern)) return true
      const clean = pattern.replace(/^\\/|\\/$/g, "")
      if (parts.includes(clean) || rel === clean || rel.startsWith(clean + "/")) return true
    }
    return false
  }

  async function scanDir(dir: string, map: Map<string, { mtimeMs: number; size: number }>): Promise<void> {
    let entries: fs.Dirent[]
    try {
      entries = await fs.promises.readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name)
      if (isIgnored(full)) continue
      if (entry.isDirectory()) {
        await scanDir(full, map)
      } else if (entry.isFile() || entry.isSymbolicLink()) {
        try {
          const stat = await fs.promises.stat(full)
          map.set(full, { mtimeMs: stat.mtimeMs, size: stat.size })
        } catch {}
      }
    }
  }

  return Effect.promise(async () => {
    let stopped = false
    let scanning = false
    let snapshot = new Map<string, { mtimeMs: number; size: number }>()

    await scanDir(directory, snapshot)

    const timer = setInterval(async () => {
      if (stopped || scanning) return
      scanning = true
      try {
        const nextSnapshot = new Map<string, { mtimeMs: number; size: number }>()
        await scanDir(directory, nextSnapshot)
        if (stopped) return

        for (const [file, curr] of nextSnapshot.entries()) {
          const prev = snapshot.get(file)
          if (!prev) {
            publish({ path: file, type: "create" })
          } else if (prev.mtimeMs !== curr.mtimeMs || prev.size !== curr.size) {
            publish({ path: file, type: "update" })
          }
        }
        for (const file of snapshot.keys()) {
          if (!nextSnapshot.has(file)) {
            publish({ path: file, type: "delete" })
          }
        }
        snapshot = nextSnapshot
      } catch {
      } finally {
        scanning = false
      }
    }, pollInterval)

    return {
      unsubscribe: async () => {
        stopped = true
        clearInterval(timer)
      },
      backend: "polling",
    }
  })
}'''
        if anchor_imports in s:
            s = s.replace(anchor_imports, helper_code, 1)

        old_native = """      if (input.type === "file" || input.type === "entries") {
        const directory = input.type === "file" ? path.dirname(input.target) : input.target
        const names = new Set(input.type === "file" ? [path.basename(input.target)] : input.names)
        return Effect.try({
          try: () =>
            watch(directory, { recursive: false }, (_event, file) => {
              if (file && !names.has(file)) return
              for (const name of file ? [file] : names) {
                input.publish({ path: path.join(directory, name), type: "update" })
              }
            }),
          catch: (error) => error,
        }).pipe(
          Effect.map((subscription): Subscription => {
            subscription.on("error", (error: unknown) =>
              Effect.runFork(Effect.logError("watcher callback failed", { path: directory, error })),
            )
            return { unsubscribe: () => Promise.resolve(subscription.close()), backend: "node" }
          }),
          // A missing directory (ENOENT) ends subscriber streams instead of crashing the watch.
          Effect.catch((error) =>
            isRecord(error) && error.code === "ENOENT"
              ? Effect.undefined
              : Effect.logError("failed to watch directory", { path: directory, error }).pipe(Effect.as(undefined)),
          ),
        )
      }"""

        new_native = """      if (input.type === "file" || input.type === "entries") {
        const directory = input.type === "file" ? path.dirname(input.target) : input.target
        if (FORBIDDEN_ANCESTORS.has(directory)) {
          return Effect.undefined
        }
        const names = new Set(input.type === "file" ? [path.basename(input.target)] : input.names)
        return Effect.try({
          try: () =>
            watch(directory, { recursive: false }, (event, file) => {
              const candidateNames = file ? [String(file)] : Array.from(names)
              for (const name of candidateNames) {
                if (names.size > 0 && !names.has(name)) continue
                const targetPath = path.join(directory, name)
                let type: Update["type"] = "update"
                if (event === "rename") {
                  try {
                    type = fs.existsSync(targetPath) ? "create" : "delete"
                  } catch {
                    type = "update"
                  }
                }
                input.publish({ path: targetPath, type })
              }
            }),
          catch: (error) => error,
        }).pipe(
          Effect.map((subscription): Subscription => {
            subscription.on("error", (error: unknown) =>
              Effect.runFork(Effect.logError("watcher callback failed", { path: directory, error })),
            )
            return { unsubscribe: () => Promise.resolve(subscription.close()), backend: "node" }
          }),
          Effect.catch((error) => {
            if (isRecord(error) && error.code === "ENOENT") return Effect.undefined
            if (isRecord(error) && (error.code === "EACCES" || error.code === "EPERM")) {
              if (!reportedEaccess.has(directory)) {
                reportedEaccess.add(directory)
                return Effect.logWarning("watcher permission denied", { path: directory, code: error.code }).pipe(
                  Effect.as(undefined),
                )
              }
              return Effect.undefined
            }
            return Effect.logError("failed to watch directory", { path: directory, error }).pipe(Effect.as(undefined))
          }),
        )
      }"""
        if old_native in s:
            s = s.replace(old_native, new_native, 1)

        old_sub_dir = """function subscribeDirectory(
  native: typeof ParcelWatcher | undefined,
  backend: ParcelWatcher.BackendType | undefined,
  directory: string,
  ignore: readonly string[],
  publish: (update: Update) => void,
): Effect.Effect<Subscription | undefined> {
  if (!native || !backend) {
    return Effect.logError("watcher backend not supported", { directory, platform: process.platform }).pipe(
      Effect.as(undefined),
    )
  }"""
        new_sub_dir = """function subscribeDirectory(
  native: typeof ParcelWatcher | undefined,
  backend: ParcelWatcher.BackendType | undefined,
  directory: string,
  ignore: readonly string[],
  publish: (update: Update) => void,
): Effect.Effect<Subscription | undefined> {
  const mode = process.env.OPENCODE_WATCHER || (process.platform === "android" ? "polling" : undefined)
  if (mode === "polling" || !backend || !native) {
    if (process.platform === "android" || mode === "polling") {
      return subscribePolling(directory, ignore, publish)
    }
    return Effect.logError("watcher backend not supported", { directory, platform: process.platform }).pipe(
      Effect.as(undefined),
    )
  }"""
        if old_sub_dir in s:
            s = s.replace(old_sub_dir, new_sub_dir, 1)

        watcher_file.write_text(s)
        print("   patched watcher.ts")
    else:
        print("   already patched watcher.ts")
PY

echo "==> 2/3 补丁 node_modules/@opentui/core（允许 android 资产目标）"
python3 - <<'PY'
import os, pathlib
# bun 1.4 的 isolated 布局把包放在隐藏目录 node_modules/.bun/... 下，glob 抓不到
roots = []
for dirpath, dirnames, _ in os.walk("."):
    if dirpath.endswith(os.path.join("node_modules", "@opentui", "core")):
        roots.append(pathlib.Path(dirpath))
        dirnames[:] = []
        continue
    dirnames[:] = [d for d in dirnames if d not in (".git", "dist", "build", ".turbo")]
if not roots:
    raise SystemExit("找不到 @opentui/core（bun install 没装 / 布局变了）")
print("   roots:", *roots)
files = [q for root in roots for q in root.rglob("*.js") if "NATIVE_FILE_NAMES" in q.read_text(errors="ignore")]
if not files:
    raise SystemExit("找不到 NATIVE_FILE_NAMES（@opentui/core 结构变了？）")
for p in files:
    s = p.read_text()
    changed = False
    if 'android: "libopentui.so"' not in s:
        s = s.replace('win32: "opentui.dll"', 'win32: "opentui.dll",\n  android: "libopentui.so"', 1)
        changed = True
    # 让原生库可以用专用环境变量定位（OPENTUI_NATIVE_LIB）。
    # 不能用 OTUI_ASSET_ROOT：那被 opentui 当作"所有资产"的根，
    # 缺 parser.worker.js / tree-sitter.wasm 就会抛
    # "Missing OpenTUI asset ..."。
    anchor = "async function resolveNativeLibraryPath() {\n  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());"
    if anchor in s and "OPENTUI_NATIVE_LIB" not in s:
        s = s.replace(anchor,
            "async function resolveNativeLibraryPath() {\n"
            "  const explicit = process.env.OPENTUI_NATIVE_LIB;\n"
            "  if (explicit) return explicit;\n"
            "  const asset = getNativeAssetDescriptor(getCurrentNodeAssetTarget());", 1)
        changed = True
    if changed:
        p.write_text(s)
        print("   patched", p)
PY

echo "==> 3/3 bun build --compile --target=bun-linux-aarch64-android"
export BUN_COMPILE_RELEASE="$RELEASE"
export OPENCODE_TARGET=android-arm64
export OTUI_ASSET_ROOT="" # 运行时注入，构建期不需要
cd packages/cli
# 默认构建嵌入 Web UI 资产（供 opencode serve 和 App WebView 消费）
# 若仅需 TUI 快速迭代，可设 SKIP_WEB_UI=1
bun run script/build.ts ${SKIP_WEB_UI:+--skip-web-ui} --skip-install

echo "==> 产物"
OUT="dist/cli-android-arm64"
find "$OUT" -maxdepth 3 -type f | head -10
BIN="$OUT/bin/opencode"
[ -f "$BIN" ] || { echo "ERROR: 没有 $BIN" >&2; exit 1; }
file "$BIN"
echo "size: $(stat -c%s "$BIN") bytes"

# bun 的 android 运行时模板本身是 16 KB 对齐的；--compile 只是把 JS 资产
# 追加上去。这里做硬性门禁：若上游 bun 模板退化为 4 KB 对齐，立即失败，
# 不把不兼容 Android 15/16 的二进制发出去。
echo "==> 16 KB 页对齐检查（Android 15/16）"
python3 "$REPO_ROOT/scripts/check-16kb-pages.py" "$BIN"

echo "==> 记录依赖库（运行时由 wrapper 注入）"
echo "libopentui: $LIBOPENTUI"
echo "librust_pty: $LIBPTY"
sha256sum "$LIBOPENTUI" "$LIBPTY" "$BIN"
