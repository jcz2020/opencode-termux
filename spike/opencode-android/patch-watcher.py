#!/usr/bin/env python3
"""给 opencode 源码打 Android 文件监听补丁。

用法：patch-watcher.py <opencode-src-dir>

设计要点（改之前先读）：
  * 所有替换都基于「源码片段锚点」，不依赖行号；上游重排代码不会打断。
  * 每处都先判断是否已打过补丁，重复执行安全（CI 重跑不会二次注入）。
  * 任何一个锚点没匹配到都只打印 WARN 继续，不中断构建；
    最终由 `scripts/smoke-static.sh` 的 OPENCODE_WATCHER 断言兜底。
  * 不要用 FSUtil.globMatch：它只是 Service 实例字段，命名空间上没有这个静态函数，
    调用会抛 TypeError（曾导致 config 目录轮询静默失效）。用 Glob.match(pattern, path)。
"""
import pathlib
import sys

WARN = []


def warn(message: str) -> None:
    WARN.append(message)
    print(f"   WARN: {message}")


def patch(path: pathlib.Path, marker: str, edits, label: str) -> None:
    """edits: [(old, new), ...] 全部按顺序、各替换一次。marker 用于判断是否已打。"""
    if not path.exists():
        warn(f"{path.name} 不存在，跳过 {label}")
        return
    s = path.read_text()
    if marker in s:
        print(f"   already patched {label}")
        return
    changed = 0
    for old, new in edits:
        if old not in s:
            warn(f"{label}: 锚点未匹配（{old.strip().splitlines()[0][:60]}…）")
            continue
        s = s.replace(old, new, 1)
        changed += 1
    if changed:
        path.write_text(s)
        print(f"   patched {label} ({changed}/{len(edits)} 处)")


# 系统根 / 无意义祖先：既不做配置发现，也不建立监听。
# /storage/emulated/0 是 Android 共享存储根，订阅它没有意义（项目根自己会被保留）。
FORBIDDEN = ["/", "/storage", "/storage/emulated", "/storage/emulated/0", "/data", "/data/data", "/etc", "/system"]

FORBIDDEN_TS = (
    "const FORBIDDEN_ANCESTORS = new Set([\n"
    '  "/",\n'
    '  "/storage",\n'
    '  "/storage/emulated",\n'
    '  "/storage/emulated/0",\n'
    '  "/data",\n'
    '  "/data/data",\n'
    '  "/etc",\n'
    '  "/system",\n'
    "])\n"
    "// $HOME 的祖先同样不可读/无意义（App 沙箱是 /data/data/<pkg>/files/home）。\n"
    "for (let dir = process.env.HOME && path.dirname(process.env.HOME); dir && dir !== \"/\" && dir !== \".\"; dir = path.dirname(dir)) {\n"
    "  FORBIDDEN_ANCESTORS.add(dir)\n"
    "}\n"
)

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
if not (ROOT / "packages/core").is_dir():
    sys.exit(f"ERROR: {ROOT} 不像 opencode 源码目录")

# ── 1. config/discovery.ts ────────────────────────────────────────────────
patch(
    ROOT / "packages/core/src/config/discovery.ts",
    'if (platform === "android")',
    [
        (
            '  if (platform === "win32") return AbsolutePath.make(path.join(env.ProgramData || "C:\\\\ProgramData", "opencode"))\n'
            '  return AbsolutePath.make("/etc/opencode")',
            '  if (platform === "win32") return AbsolutePath.make(path.join(env.ProgramData || "C:\\\\ProgramData", "opencode"))\n'
            '  if (platform === "android") {\n'
            '    // Android 没有 /etc/opencode；用 Termux prefix 下的 etc，且它可读可监听。\n'
            '    const prefix = env.PREFIX || "/data/data/com.termux/files/usr"\n'
            '    return AbsolutePath.make(path.join(prefix, "etc", "opencode"))\n'
            '  }\n'
            '  return AbsolutePath.make("/etc/opencode")',
        ),
        (
            "  const current = yield* fs.resolve(location.directory)\n  const directories =",
            # 保留项目根自己（d === current），只砍它上面的系统/共享存储根。
            "  const current = yield* fs.resolve(location.directory)\n"
            "  // Android：项目根之上的系统根 / 共享存储根既不可读也没有配置意义。\n"
            "  const forbiddenAncestors = new Set([\n"
            + "".join(f'    "{item}",\n' for item in FORBIDDEN)
            + "  ])\n"
            "  const directories =",
        ),
        (
            '      : yield* fs.up({ targets: ["."], start: location.directory }).pipe(Effect.orDie)',
            '      : (yield* fs.up({ targets: ["."], start: location.directory }).pipe(Effect.orDie)).filter(\n'
            '          (d) => d === current || !forbiddenAncestors.has(d),\n'
            '        )',
        ),
    ],
    "discovery.ts",
)

# ── 2. config/watch.ts ────────────────────────────────────────────────────
patch(
    ROOT / "packages/core/src/config/watch.ts",
    "FORBIDDEN_ANCESTORS",
    [
        (
            """  // Keep a parent watch for each root so deletion/recreation is observable.
  const parents = Map.groupBy(
    files.filter((file) => !directories.some((directory) => file !== directory && FSUtil.contains(directory, file))),
    (file) => path.dirname(file),
  )""",
            """  // Keep a parent watch for each root so deletion/recreation is observable.
  // 但不要订阅系统根 / 共享存储根：Android 上它们要么 EACCES，要么毫无意义。
  const FORBIDDEN_ANCESTORS = new Set([
    "/",
    "/storage",
    "/storage/emulated",
    "/storage/emulated/0",
    "/data",
    "/data/data",
    "/etc",
    "/system",
  ])
  const parents = Map.groupBy(
    files.filter((file) => {
      if (FORBIDDEN_ANCESTORS.has(path.dirname(file))) return false
      return !directories.some((directory) => file !== directory && FSUtil.contains(directory, file))
    }),
    (file) => path.dirname(file),
  )""",
        )
    ],
    "watch.ts",
)

# ── 3. filesystem/location-watcher.ts ────────────────────────────────────
patch(
    ROOT / "packages/core/src/filesystem/location-watcher.ts",
    "reconcileWorkspace",
    [
        (
            "    let active: { path: string; scope: Scope.Closeable } | undefined",
            "    let active: { path: string; scope: Scope.Closeable } | undefined\n"
            "    let activeWorkspace: { scope: Scope.Closeable; ignore: string } | undefined\n"
            "    // 工作区整目录监听：外部编辑器（含 Android FUSE 跨 UID）的增/改/删 -> filesystem.changed。\n"
            "    const reconcileWorkspace = () =>\n"
            "      lock.withPermit(\n"
            "        Effect.gen(function* () {\n"
            "          if (stopped) return\n"
            "          const ignoreList = policy.current()\n"
            "          const ignoreKey = JSON.stringify(ignoreList)\n"
            "          if (activeWorkspace?.ignore === ignoreKey) return\n"
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
            "              (cause) =>\n"
            "                Effect.logError(\"workspace watcher subscription failed\", { directory: location.directory, cause }),\n"
            "            ),\n"
            "            Effect.forkIn(scope, { startImmediately: true }),\n"
            "          )\n"
            "        }).pipe(\n"
            "          Effect.withSpan(\"LocationWatcher.reconcileWorkspace\", {\n"
            "            attributes: { directory: location.directory },\n"
            "          }),\n"
            "        ),\n"
            "      )",
        ),
        (
            """    yield* Effect.addFinalizer(() =>
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
    }).pipe(""",
            """    yield* Effect.addFinalizer(() =>
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
    }).pipe(""",
        ),
    ],
    "location-watcher.ts",
)

# ── 4. filesystem/watcher.ts ─────────────────────────────────────────────
POLLING = f"""import loadBinding from "./watcher-binding.js"
import fs from "node:fs"
import {{ Glob }} from "@opencode/util/glob"

{FORBIDDEN_TS}
// EACCES/EPERM 只提示一次，避免冷启动刷屏。
const reportedDenied = new Set<string>()

type Snapshot = Map<string, {{ mtimeMs: number; ctimeMs: number; size: number; dir: boolean }}>

function createScanner(root: string, ignore: readonly string[]) {{
  const ignoreList = [...ignore]
  const isIgnored = (target: string) => {{
    const rel = path.relative(root, target).replace(/\\\\/g, "/")
    if (!rel || rel === ".") return false
    const parts = rel.split("/")
    for (const part of parts) {{
      if (FSUtil.ignoredDirectories.includes(part)) return true
    }}
    for (const pattern of ignoreList) {{
      if (Glob.match(pattern, rel)) return true
    }}
    return false
  }}
  const walk = async (dir: string, into: Snapshot) => {{
    let entries: fs.Dirent[]
    try {{
      entries = await fs.promises.readdir(dir, {{ withFileTypes: true }})
    }} catch {{
      return
    }}
    for (const entry of entries) {{
      const full = path.join(dir, entry.name)
      try {{
        if (isIgnored(full)) continue
        if (entry.isDirectory()) {{
          const stat = await fs.promises.stat(full)
          into.set(full, {{ mtimeMs: stat.mtimeMs, ctimeMs: stat.ctimeMs, size: 0, dir: true }})
          await walk(full, into)
        }} else if (entry.isFile() || entry.isSymbolicLink()) {{
          const stat = await fs.promises.stat(full)
          into.set(full, {{ mtimeMs: stat.mtimeMs, ctimeMs: stat.ctimeMs, size: stat.size, dir: false }})
        }}
      }} catch {{
        // 竞态：扫描途中被删/被改权限，跳过即可。
      }}
    }}
  }}
  return {{ walk }}
}}

/**
 * Android / 显式 OPENCODE_WATCHER=polling 时使用的目录监听。
 *
 * 为什么是轮询：/storage/emulated/0 是 FUSE，跨应用 UID 写入（外部编辑器、
 * 原子 rename 保存）时 inotify 事件会丢；递归快照 diff 虽然慢一点但确定性最好。
 */
function subscribePolling(
  directory: string,
  ignore: readonly string[],
  publish: (update: Update) => void,
): Effect.Effect<Subscription | undefined> {{
  if (FORBIDDEN_ANCESTORS.has(directory)) {{
    return Effect.undefined
  }}
  const parsed = Number.parseInt(process.env.OPENCODE_WATCHER_POLL_INTERVAL || "", 10)
  const interval = Number.isFinite(parsed) && parsed >= 250 ? parsed : 1000
  const {{ walk }} = createScanner(directory, ignore)

  return Effect.promise(async () => {{
    let stopped = false
    let scanning = false
    let snapshot: Snapshot = new Map()

    // 起始快照不产生事件：启动前就存在的文件不算变更。
    try {{
      await walk(directory, snapshot)
    }} catch {{
      snapshot = new Map()
    }}

    const poll = async () => {{
      if (stopped || scanning) return
      scanning = true
      try {{
        const next: Snapshot = new Map()
        await walk(directory, next)
        if (stopped) return
        for (const [file, curr] of next) {{
          const prev = snapshot.get(file)
          if (!prev) {{
            publish({{ path: file, type: "create" }})
          }} else if (
            prev.mtimeMs !== curr.mtimeMs ||
            prev.ctimeMs !== curr.ctimeMs ||
            prev.size !== curr.size ||
            prev.dir !== curr.dir
          ) {{
            publish({{ path: file, type: "update" }})
          }}
        }}
        for (const file of snapshot.keys()) {{
          if (!next.has(file)) publish({{ path: file, type: "delete" }})
        }}
        snapshot = next
      }} catch {{
        // 单次扫描失败不影响后续轮询。
      }} finally {{
        scanning = false
      }}
    }}

    const timer = setInterval(poll, interval)
    return {{
      unsubscribe: async () => {{
        stopped = true
        clearInterval(timer)
      }},
      backend: "polling",
    }}
  }})
}}
"""

patch(
    ROOT / "packages/core/src/filesystem/watcher.ts",
    "subscribePolling",
    [
        (
            'import loadBinding from "./watcher-binding.js"',
            POLLING,
        ),
        (
            """      if (input.type === "file" || input.type === "entries") {
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
      }""",
            """      if (input.type === "file" || input.type === "entries") {
        const directory = input.type === "file" ? path.dirname(input.target) : input.target
        if (FORBIDDEN_ANCESTORS.has(directory)) {
          return Effect.undefined
        }
        // entries 的 names 为空时不要过滤：否则新建文件永远进不来。
        const names = new Set(input.type === "file" ? [path.basename(input.target)] : input.names)
        return Effect.try({
          try: () =>
            watch(directory, { recursive: false }, (event, file) => {
              const candidates = file ? [String(file)] : Array.from(names)
              for (const name of candidates) {
                if (names.size > 0 && !names.has(name)) continue
                const target = path.join(directory, name)
                // rename 既可能是新建也可能是删除/移走，用 exists 判定，别再一律发 update。
                let type: Update["type"] = "update"
                if (event === "rename") {
                  try {
                    type = fs.existsSync(target) ? "create" : "delete"
                  } catch {
                    type = "update"
                  }
                }
                input.publish({ path: target, type })
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
            // A missing directory (ENOENT) ends subscriber streams instead of crashing the watch.
            if (isRecord(error) && error.code === "ENOENT") return Effect.undefined
            if (isRecord(error) && (error.code === "EACCES" || error.code === "EPERM")) {
              if (reportedDenied.has(directory)) return Effect.undefined
              reportedDenied.add(directory)
              return Effect.logDebug("watcher permission denied", { path: directory, code: error.code }).pipe(
                Effect.as(undefined),
              )
            }
            return Effect.logError("failed to watch directory", { path: directory, error }).pipe(Effect.as(undefined))
          }),
        )
      }""",
        ),
        (
            """function subscribeDirectory(
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
  }""",
            """function subscribeDirectory(
  native: typeof ParcelWatcher | undefined,
  backend: ParcelWatcher.BackendType | undefined,
  directory: string,
  ignore: readonly string[],
  publish: (update: Update) => void,
): Effect.Effect<Subscription | undefined> {
  // Android 没有 @parcel/watcher 预编译 binding，默认走轮询快照；
  // OPENCODE_WATCHER=node 可强制回退到原生 fs.watch（仅 type=file/entries 生效）。
  const mode = process.env.OPENCODE_WATCHER
  if (mode === "polling" || process.platform === "android" || !native || !backend) {
    if (mode === "node") {
      return Effect.logError("watcher backend not supported", { directory, platform: process.platform }).pipe(
        Effect.as(undefined),
      )
    }
    if (mode === "polling" || process.platform === "android") {
      return subscribePolling(directory, ignore, publish)
    }
    return Effect.logError("watcher backend not supported", { directory, platform: process.platform }).pipe(
      Effect.as(undefined),
    )
  }""",
        ),
    ],
    "watcher.ts",
)

print("Android watcher 补丁完成" + (f"（{len(WARN)} 个锚点告警）" if WARN else ""))
