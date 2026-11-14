#!/data/data/com.termux/files/usr/bin/bash
# smoke-watcher.sh — 验证 Android 文件监听（watcher）与 EACCES 噪音收敛。
#
# 验证点：
#   1. 冷启动日志中不再包含 "watcher backend not supported" 与 "failed to watch directory: EACCES"
#   2. /api/event 能够接收到工作区文件的增、删、改事件（filesystem.changed）
set -euo pipefail

command -v opencode >/dev/null || { echo "SKIP: 没装 opencode"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: 没装 python3"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-watcher-smoke.XXXXXX" 2>/dev/null || mktemp -d)"
WORKSPACE="$TMP/workspace"
mkdir -p "$WORKSPACE" "$TMP/home" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

iso() {
  env \
    HOME="$TMP/home" \
    XDG_STATE_HOME="$TMP/state" \
    XDG_DATA_HOME="$TMP/data" \
    XDG_CONFIG_HOME="$TMP/config" \
    XDG_CACHE_HOME="$TMP/cache" \
    TMPDIR="$TMP/cache" \
    PREFIX="${PREFIX:-/data/data/com.termux/files/usr}" \
    PATH="${PREFIX:-/data/data/com.termux/files/usr}/bin:/system/bin" \
    SHELL=/system/bin/sh \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    "$@"
}

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> 启动 opencode serve (port $PORT, workspace $WORKSPACE)"
iso opencode serve --hostname 127.0.0.1 --port "$PORT" >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!

echo "==> 等待服务就绪..."
READY=false
for _ in $(seq 30); do
  if grep -qE "Listening on http://127.0.0.1:$PORT|Serving on http://127.0.0.1:$PORT" "$TMP/serve.log" 2>/dev/null \
     || curl -sf "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 0.5
done

if [ "$READY" != "true" ]; then
  echo "FAIL: opencode serve 启动超时" >&2
  cat "$TMP/serve.log" >&2
  exit 1
fi

echo "==> 检查日志噪音 (EACCES 与 backend unsupported)"
if grep -q "watcher backend not supported" "$TMP/serve.log"; then
  echo "FAIL: 日志命中 'watcher backend not supported'" >&2
  cat "$TMP/serve.log" >&2
  exit 1
fi
if grep -q "failed to watch directory: EACCES" "$TMP/serve.log"; then
  echo "FAIL: 日志命中 'failed to watch directory: EACCES'" >&2
  cat "$TMP/serve.log" >&2
  exit 1
fi
echo "  OK: 无 EACCES / unsupported 噪音"

echo "==> 测试文件变更事件流 (/api/event -> filesystem.changed)"
python3 - <<PY
import urllib.request
import json
import time
import os
import threading
import sys

events = []
stop_event = threading.Event()

def read_sse():
    url = "http://127.0.0.1:$PORT/api/event"
    req = urllib.request.Request(url, headers={"Accept": "text/event-stream"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            for line in resp:
                if stop_event.is_set():
                    break
                decoded = line.decode("utf-8").strip()
                if decoded.startswith("data:"):
                    raw = decoded[5:].strip()
                    try:
                        data = json.loads(raw)
                        if data.get("type") == "filesystem.changed":
                            events.append(data.get("data", {}))
                    except Exception:
                        pass
    except Exception:
        pass

t = threading.Thread(target=read_sse, daemon=True)
t.start()
time.sleep(1) # wait for SSE stream to connect

# 1. 创建文件
ws = "$WORKSPACE"
f1 = os.path.join(ws, "test1.txt")
with open(f1, "w") as f:
    f.write("hello")
time.sleep(1.5)

# 2. 修改文件
with open(f1, "w") as f:
    f.write("hello world modified")
time.sleep(1.5)

# 3. 创建子目录与子文件
subdir = os.path.join(ws, "subdir")
os.makedirs(subdir, exist_ok=True)
f2 = os.path.join(subdir, "nested.txt")
with open(f2, "w") as f:
    f.write("nested")
time.sleep(1.5)

# 4. 删除文件
os.remove(f1)
time.sleep(1.5)

stop_event.set()

print(f"Captured {len(events)} filesystem.changed events:")
for e in events:
    print("  ", e)

# 校验必须捕获 add, change, unlink
actions = [e.get("event") for e in events]
if "add" not in actions:
    print("FAIL: 未捕获到 add 事件", file=sys.stderr)
    sys.exit(1)
if "change" not in actions:
    print("FAIL: 未捕获到 change 事件", file=sys.stderr)
    sys.exit(1)
if "unlink" not in actions:
    print("FAIL: 未捕获到 unlink 事件", file=sys.stderr)
    sys.exit(1)

print("OK: 文件增删改均成功接收到 filesystem.changed 事件")
PY

echo "OK: watcher smoke 通过"
