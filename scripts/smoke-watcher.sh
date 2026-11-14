#!/data/data/com.termux/files/usr/bin/bash
# smoke-watcher.sh — Android 文件监听（watcher）端到端冒烟。
#
# 验证三件事（对应 3 个真机 bug）：
#   1. 冷启动不再刷 "watcher backend not supported" / "failed to watch directory: EACCES"
#   2. 工作区增/改/删/子目录变更能通过 SSE /api/event 变成 filesystem.changed
#   3. 配置目录新增文件能触发热重载（不重启进程）
#
# 用法：
#   make smoke-watcher                      # 用已安装的 opencode
#   OPENCODE_BIN=/path/to/opencode ./smoke-watcher.sh
#   WORKSPACE=/storage/emulated/0/OpenCode/watch-smoke ./smoke-watcher.sh  # 指定 FUSE 工作区
set -euo pipefail

BIN="${OPENCODE_BIN:-$(command -v opencode || true)}"
[ -n "$BIN" ] || { echo "SKIP: 没装 opencode（可用 OPENCODE_BIN 指定）"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: 没装 python3"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-watcher.XXXXXX" 2>/dev/null || mktemp -d)"
WORKSPACE="${WORKSPACE:-$TMP/workspace}"
CONFIG="$TMP/config/opencode"
mkdir -p "$WORKSPACE" "$TMP/home" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache" "$CONFIG"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 20); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> 启动 serve（port $PORT）"
echo "    workspace: $WORKSPACE"
cd "$WORKSPACE"
env \
  HOME="$TMP/home" \
  XDG_STATE_HOME="$TMP/state" \
  XDG_DATA_HOME="$TMP/data" \
  XDG_CONFIG_HOME="$TMP/config" \
  XDG_CACHE_HOME="$TMP/cache" \
  TMPDIR="$TMP/cache" \
  PREFIX="${PREFIX:-/data/data/com.termux/files/usr}" \
  PATH="$(dirname "$BIN"):${PREFIX:-/data/data/com.termux/files/usr}/bin:/system/bin" \
  SHELL=/system/bin/sh \
  OPENCODE_DISABLE_AUTOUPDATE=true \
  "$BIN" serve --hostname 127.0.0.1 --port "$PORT" >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!

READY=false
for _ in $(seq 40); do
  if grep -q "server listening on http://127.0.0.1:$PORT" "$TMP/serve.log" 2>/dev/null; then READY=true; break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$READY" != "true" ]; then
  echo "FAIL: serve 没起来" >&2
  cat "$TMP/serve.log" >&2
  exit 1
fi

PASSWORD="$(sed -n 's/^server password //p' "$TMP/serve.log" | tail -1)"
[ -n "$PASSWORD" ] || { echo "FAIL: 没拿到 server password" >&2; cat "$TMP/serve.log" >&2; exit 1; }

echo "==> 端到端校验"
PORT="$PORT" PASSWORD="$PASSWORD" WORKSPACE="$WORKSPACE" CONFIG="$CONFIG" \
LOGDIR="$TMP/data/opencode/log" STDLOG="$TMP/serve.log" \
python3 - <<'PY'
import base64, glob, json, os, sys, threading, time, urllib.request, urllib.error

port = os.environ["PORT"]
auth = "Basic " + base64.b64encode(("opencode:" + os.environ["PASSWORD"]).encode()).decode()
ws = os.environ["WORKSPACE"]
config = os.environ["CONFIG"]
logdir = os.environ["LOGDIR"]
stdlog = os.environ["STDLOG"]
failures = []

def check(name, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL'}] {name}")
    if not ok:
        failures.append(f"{name} {detail}".strip())

def api(path, timeout=20):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"Authorization": auth})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"null")

def read_logs():
    chunks = []
    try:
        chunks.append(open(stdlog, encoding="utf-8", errors="replace").read())
    except FileNotFoundError:
        pass
    for path in glob.glob(os.path.join(logdir, "*.log")):
        try:
            chunks.append(open(path, encoding="utf-8", errors="replace").read())
        except FileNotFoundError:
            pass
    return "\n".join(chunks)

events, lock, stop = [], threading.Lock(), threading.Event()

def sse():
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/event",
        headers={"Accept": "text/event-stream", "Authorization": auth},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            for line in resp:
                if stop.is_set():
                    return
                text = line.decode("utf-8", "replace")
                if not text.startswith("data:"):
                    continue
                try:
                    data = json.loads(text[5:].strip())
                except Exception:
                    continue
                if data.get("type") == "filesystem.changed":
                    with lock:
                        events.append(data["data"])
    except Exception:
        return

# 1) 冷启动噪音
noise = read_logs()
check("无 'watcher backend not supported'", "watcher backend not supported" not in noise)
check("无 'failed to watch directory'", "failed to watch directory" not in noise)
check("无 EACCES 刷屏", noise.count("EACCES") == 0, f"出现 {noise.count('EACCES')} 次")

# 2) 工作区事件
threading.Thread(target=sse, daemon=True).start()

# LocationWatcher 是懒加载的：先显式拉起，并等目录监听真正 start，
# 否则测试文件会写进「起始快照」，看起来像「没有事件」。
api("/api/location")
deadline = time.time() + 40
while time.time() < deadline:
    log = read_logs()
    if f"path={ws} type=directory" in log:
        break
    time.sleep(0.5)
else:
    check("工作区目录监听已启动", False, "40s 内没等到 watcher subscribe/start")

time.sleep(1)

existing = os.path.join(ws, "existing.txt")
open(existing, "w").write("v0\n")
time.sleep(1.5)
open(existing, "w").write("v0 modified in place\n")   # 真正的「修改已存在文件」
time.sleep(1.5)

sub = os.path.join(ws, "sub", "deep")
os.makedirs(sub, exist_ok=True)
child = os.path.join(sub, "child.txt")
open(child, "w").write("child v0\n")
time.sleep(1.5)
open(child, "w").write("child v1 modified\n")
time.sleep(1.5)

renamed = os.path.join(ws, "renamed.txt")
top_new = os.path.join(ws, "new-top.txt")
open(top_new, "w").write("new\n")
time.sleep(1.5)

os.rename(top_new, renamed)
time.sleep(1.5)
os.remove(renamed)
time.sleep(1.5)

with lock:
    seen = {(os.path.relpath(e["file"], ws), e["event"]) for e in events}

check("修改已存在顶层文件 -> change", ("existing.txt", "change") in seen)
check("新建顶层文件 -> add", ("new-top.txt", "add") in seen)
check("子目录 -> add", (os.path.join("sub", "deep"), "add") in seen)
check("子目录内新文件 -> add", (os.path.join("sub", "deep", "child.txt"), "add") in seen)
check("子目录内文件修改 -> change", (os.path.join("sub", "deep", "child.txt"), "change") in seen)
check("重命名 -> add", ("renamed.txt", "add") in seen)
check("删除 -> unlink", ("renamed.txt", "unlink") in seen)
if failures:
    print(f"    实际事件: {sorted(seen)}")

# 3) 配置目录热重载
before = {a.get("id") for a in api("/api/agent").get("data", [])}
os.makedirs(os.path.join(config, "agent"), exist_ok=True)
open(os.path.join(config, "agent", "hot-reload-probe.md"), "w").write(
    "---\ndescription: created while the server is running\nmode: subagent\n---\nprobe\n"
)
after = before
for _ in range(15):
    time.sleep(1)
    after = {a.get("id") for a in api("/api/agent").get("data", [])}
    if "hot-reload-probe" in after:
        break
check("配置目录新增 agent 热重载", "hot-reload-probe" in after)

stop.set()
print()
if failures:
    print(f"=== watcher 冒烟失败（{len(failures)} 项）===")
    for item in failures:
        print(f"  - {item}")
    log = read_logs()
    if log:
        print("--- 日志尾部 ---")
        print("\n".join(log.splitlines()[-25:]))
    sys.exit(1)
print("=== watcher 冒烟通过 ===")
PY
