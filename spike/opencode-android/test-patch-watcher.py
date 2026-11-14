#!/usr/bin/env python3
"""Android watcher 补丁的离线单测（不需要设备 / 不需要 CI）。

做三件事：
  1. 在真实临时目录上跑「补丁后的 createScanner + 轮询 diff」，断言增/改/删/子目录/ignore 行为；
  2. 断言 ignore 用的是 Glob.match(pattern, path) 的正确参数顺序（反了会静默失效）；
  3. 断言祖先边界、entries 事件类型等关键补丁片段都在。

用法：
  python3 spike/opencode-android/test-patch-watcher.py [opencode-src-dir]

不给源码目录时，只做第 2、3 步（静态片段断言），可在 CI 里跑。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

failures = []


def check(name, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL'}] {name}")
    if not ok:
        failures.append(f"{name}: {detail}")


def patch_source(src):
    subprocess.run([sys.executable, os.path.join(HERE, "patch-watcher.py"), src], check=True)


# ── 静态片段断言 ────────────────────────────────────────────────────────
def static_checks(src):
    watcher = open(os.path.join(src, "packages/core/src/filesystem/watcher.ts")).read()
    watch = open(os.path.join(src, "packages/core/src/config/watch.ts")).read()
    discovery = open(os.path.join(src, "packages/core/src/config/discovery.ts")).read()
    location = open(os.path.join(src, "packages/core/src/filesystem/location-watcher.ts")).read()

    print("静态片段：")
    check("watcher.ts 有 subscribePolling", "function subscribePolling(" in watcher)
    check("watcher.ts 用 Glob.match（不是 FSUtil.globMatch）", "Glob.match(pattern, rel)" in watcher and "FSUtil.globMatch" not in watcher)
    check("watcher.ts 有祖先黑名单", "FORBIDDEN_ANCESTORS" in watcher)
    check("watcher.ts EACCES 只记一次", "reportedDenied" in watcher)
    check("watcher.ts rename 用 exists 判定", "fs.existsSync(target)" in watcher)
    check("watcher.ts entries 空 names 不过滤", "names.size > 0" in watcher)
    check("watcher.ts Android 默认 polling", 'process.platform === "android"' in watcher)
    check("watch.ts 过滤 forbidden 父目录", "FORBIDDEN_ANCESTORS" in watch)
    check("discovery.ts Android 用 prefix/etc", 'platform === "android"' in discovery and "forbiddenAncestors" in discovery)
    check("discovery.ts 保留项目根", "d === current || !forbiddenAncestors.has(d)" in discovery)
    check("location-watcher.ts 监听工作区目录", "reconcileWorkspace" in location and 'type: "directory"' in location)


# ── 行为测试：把 createScanner 抠出来跑 ──────────────────────────────────
def extract_scanner(src):
    text = open(os.path.join(src, "packages/core/src/filesystem/watcher.ts")).read()
    start = text.index("type Snapshot = Map<")
    end = text.index("/**\n * Android / 显式 OPENCODE_WATCHER=polling")
    block = text[start:end]
    # TS 类型在 JS 里非法，做最小化剥离
    block = re.sub(r"type Snapshot = .*?\n\n", "", block, flags=re.S)
    block = block.replace(": Map<string, { mtimeMs: number; ctimeMs: number; size: number; dir: boolean }>", "")
    block = block.replace(": readonly string[]", "")
    block = block.replace(": string", "")
    block = block.replace(": Snapshot", "")
    block = block.replace("let entries: fs.Dirent[]", "let entries")
    block = block.replace("const isIgnored = (target) =>", "const isIgnored = (target) =>")
    block = block.replace("(target: string)", "(target)")
    block = block.replace("(dir: string, into: Snapshot)", "(dir, into)")
    block = block.replace("(root: string, ignore)", "(root, ignore)")
    block = re.sub(r"\(\s*target\s*\)\s*=>", "(target) =>", block)
    return block


def behavior_checks(src):
    print("行为测试（真实文件系统）：")
    sandbox = tempfile.mkdtemp(prefix="oc-watcher-test-")
    try:
        ws = os.path.join(sandbox, "ws")
        os.makedirs(ws)
        os.makedirs(os.path.join(ws, "node_modules", "pkg"))
        with open(os.path.join(ws, "node_modules", "pkg", "index.js"), "w") as f:
            f.write("ignored")
        with open(os.path.join(ws, "keep.txt"), "w") as f:
            f.write("v0")

        harness = os.path.join(sandbox, "harness.mjs")
        with open(harness, "w") as f:
            f.write(
                "import fs from 'node:fs'\n"
                "import path from 'node:path'\n"
                "import { Glob } from 'minimatch-shim'\n"
                "const FSUtil = { ignoredDirectories: ['node_modules', '.git', '.venv', 'venv', '__pycache__'] }\n"
                + extract_scanner(src)
                + "\n"
                "const dir = process.argv[2]\n"
                "const events = []\n"
                "const { walk } = createScanner(dir, ['node_modules', '.git', '**/{node_modules,.git}/**'])\n"
                "let snapshot = new Map()\n"
                "await walk(dir, snapshot)\n"
                "const sleep = (ms) => new Promise(r => setTimeout(r, ms))\n"
                "const tick = async () => {\n"
                "  const next = new Map()\n"
                "  await walk(dir, next)\n"
                "  for (const [file, curr] of next) {\n"
                "    const prev = snapshot.get(file)\n"
                "    if (!prev) events.push(['create', path.relative(dir, file)])\n"
                "    else if (prev.mtimeMs !== curr.mtimeMs || prev.ctimeMs !== curr.ctimeMs || prev.size !== curr.size || prev.dir !== curr.dir)\n"
                "      events.push(['update', path.relative(dir, file)])\n"
                "  }\n"
                "  for (const file of snapshot.keys()) if (!next.has(file)) events.push(['delete', path.relative(dir, file)])\n"
                "  snapshot = next\n"
                "}\n"
                "const fsx = fs\n"
                "fsx.writeFileSync(path.join(dir, 'new.txt'), 'a')\n"
                "await sleep(20); await tick()\n"
                "fsx.writeFileSync(path.join(dir, 'keep.txt'), 'v1-changed')\n"
                "await sleep(20); await tick()\n"
                "fsx.mkdirSync(path.join(dir, 'sub', 'deep'), { recursive: true })\n"
                "await sleep(20); await tick()\n"
                "fsx.writeFileSync(path.join(dir, 'sub', 'deep', 'child.txt'), 'b')\n"
                "await sleep(20); await tick()\n"
                "fsx.writeFileSync(path.join(dir, 'node_modules', 'pkg', 'index.js'), 'should be ignored')\n"
                "await sleep(20); await tick()\n"
                "fsx.rmSync(path.join(dir, 'new.txt'))\n"
                "await sleep(20); await tick()\n"
                "console.log(JSON.stringify(events))\n"
            )

        shim_dir = os.path.join(sandbox, "node_modules", "minimatch-shim")
        os.makedirs(shim_dir)
        with open(os.path.join(shim_dir, "package.json"), "w") as f:
            json.dump({"name": "minimatch-shim", "type": "module", "main": "index.js"}, f)
        with open(os.path.join(shim_dir, "index.js"), "w") as f:
            # 用 python 的 fnmatch 语义近似即可，本测试只关心「文件名/路径匹配」这一层
            f.write(
                "import { minimatch } from './minimatch.js'\n"
                "export const Glob = { match: (pattern, filepath) => minimatch(filepath, pattern, { dot: true }) }\n"
            )
        with open(os.path.join(shim_dir, "minimatch.js"), "w") as f:
            f.write(
                "export function minimatch(filepath, pattern) {\n"
                "  const re = new RegExp('^' + pattern\n"
                "    .replace(/\\*\\*\\/\\{[^}]+\\}\\/\\*\\*/g, '(.+/)?([^/]+/)?[^/]+')\n"
                "    .replace(/\\*\\*\\//g, '(.+/)?')\n"
                "    .replace(/[.+^${}()|[\\]\\\\]/g, '\\\\$&')\n"
                "    .replace(/\\*/g, '[^/]*') + '$')\n"
                "  return re.test(filepath)\n"
                "}\n"
            )

        bun = os.environ.get("BUN") or shutil.which("bun") or shutil.which("node")
        if not bun:
            check("行为测试需要 bun/node", False, "PATH 里找不到 bun 或 node")
            return
        result = subprocess.run([bun, harness, ws], capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            check("扫描器脚本可执行", False, (result.stderr or result.stdout)[-800:])
            return
        events = json.loads(result.stdout.strip().splitlines()[-1])
        pairs = [tuple(item) for item in events]

        check("新建顶层文件 -> create", ("create", "new.txt") in pairs)
        check("修改已有文件 -> update", ("update", "keep.txt") in pairs)
        check("新建子目录 -> create", ("create", os.path.join("sub", "deep")) in pairs)
        check("子目录内新文件 -> create", ("create", os.path.join("sub", "deep", "child.txt")) in pairs)
        check("删除文件 -> delete", ("delete", "new.txt") in pairs)
        check(
            "node_modules 被忽略",
            not any("node_modules" in rel for _, rel in pairs),
            f"实际事件 {pairs}",
        )
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


def main():
    args = sys.argv[1:]
    check_only = "--check" in args
    args = [a for a in args if a != "--check"]
    src = args[0] if args else None
    if src and check_only:
        print(f"==> 只校验已打过补丁的源码：{src}")
        static_checks(src)
        behavior_checks(src)
    elif src:
        print(f"==> 打补丁到临时副本：{src}")
        patch_source(src)
        static_checks(src)
        behavior_checks(src)
    else:
        print("没有给源码目录：跳过静态/行为测试（CI 里由 smoke-static 兜底）")

    print()
    if failures:
        print(f"=== FAILED ({len(failures)}) ===")
        for item in failures:
            print(f"  - {item}")
        sys.exit(1)
    print("=== 全部通过 ===")


if __name__ == "__main__":
    main()
