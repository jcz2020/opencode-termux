#!/data/data/com.termux/files/usr/bin/bash
# smoke-pty-leak.sh — opencode-pty 僵尸（Z）泄漏门禁。
#
# 背景：上游 pipe 子进程退出后是「故意保留的僵尸」，只有 terminate 才 reap；
# opencode 侧只在 25 条历史溢出时 eviction，所以长会话会稳定残留 25 个 Z。
# 本脚本验证修复后「命令结束即回收」，并把 Z 计数纳入门禁。
#
# 覆盖：
#   1. 50 条 agent shell 命令（正常 / 非 0 / 超时 / 取消）后 Z == 0
#   2. 50 次 PTY 创建/删除后 Z == 0
#   3. 空闲 10s 后仍为 0（没有延迟堆积）
#   4. 行为不回归：exit code、status(timeout/killed)、输出内容
#
# 注意：daemon 的 socket 路径是
#   $OPENCODE_PTY_SOCKET_DIR/opencode-pty-<uid>/<32hex>.sock
# 后缀固定占 56 字节，超过 SUN_LEN 时 daemon 会直接退出、opencode 静默退化成
# spawned shell（Z=0 但根本没测到 daemon）。所以这里强制用短 TMPDIR，
# 并且**断言 daemon 真的起来了**，起不来就 FAIL。
#
# 用法：
#   make smoke-pty-leak
#   OPENCODE_BIN=/path/to/opencode PREFIX=/path/to/prefix ./smoke-pty-leak.sh
set -euo pipefail

BIN="${OPENCODE_BIN:-$(command -v opencode || true)}"
[ -n "$BIN" ] || { echo "SKIP: 没装 opencode（可用 OPENCODE_BIN 指定）"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: 没装 python3"; exit 0; }

PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
# 迟一点再做长度检查：socket 路径 = TMPDIR/opty + 56。
SHORT_TMP="$PREFIX_DIR/tmp"
mkdir -p "$SHORT_TMP" 2>/dev/null || true
if [ ! -w "$SHORT_TMP" ]; then
  echo "FAIL: $SHORT_TMP 不可写；需要一个短的 TMPDIR 来放 PTY socket" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-pty-leak.XXXXXX" 2>/dev/null || mktemp -d)"
WS="$TMP/workspace"
mkdir -p "$WS" "$TMP/home" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache"

PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 30); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> 启动 serve（port $PORT）"
echo "    workspace: $WS"
echo "    TMPDIR:    $SHORT_TMP（PTY socket: $SHORT_TMP/opty）"
cd "$WS"
env \
  HOME="$TMP/home" \
  XDG_STATE_HOME="$TMP/state" \
  XDG_DATA_HOME="$TMP/data" \
  XDG_CONFIG_HOME="$TMP/config" \
  XDG_CACHE_HOME="$TMP/cache" \
  TMPDIR="$SHORT_TMP" \
  PREFIX="$PREFIX_DIR" \
  PATH="$(dirname "$BIN"):$PREFIX_DIR/bin:/system/bin" \
  SHELL=/system/bin/sh \
  OPENCODE_DISABLE_AUTOUPDATE=true \
  "$BIN" serve --hostname 127.0.0.1 --port "$PORT" >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!

READY=false
for _ in $(seq 60); do
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

echo "==> 僵尸门禁"
PORT="$PORT" PASSWORD="$PASSWORD" SOCK_DIR="$SHORT_TMP/opty" \
python3 - <<'PY'
import base64, json, os, sys, time, urllib.error, urllib.request

port = os.environ["PORT"]
sock_dir = os.environ["SOCK_DIR"]
auth = "Basic " + base64.b64encode(("opencode:" + os.environ["PASSWORD"]).encode()).decode()
failures = []

def check(name, ok, detail=""):
    print(f"  [{'OK' if ok else 'FAIL'}] {name}{(' — ' + str(detail)) if detail and not ok else ''}")
    if not ok:
        failures.append(f"{name} {detail}".strip())

def read(path, default=""):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return default

def table():
    rows = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        stat = read(f"/proc/{pid}/stat").strip()
        if not stat:
            continue
        try:
            comm = stat[stat.index("(") + 1:stat.rindex(")")]
            fields = stat[stat.rindex(")") + 1:].split()
            state, ppid = fields[0], int(fields[1])
        except (ValueError, IndexError):
            continue
        rows.append({"pid": pid, "ppid": ppid, "state": state, "comm": comm})
    return rows

def daemons(rows=None):
    rows = rows or table()
    return [r for r in rows if "opencode-pty" in read(f"/proc/{r['pid']}/cmdline") and " daemon " in f" {read(f'/proc/{r["pid"]}/cmdline').replace(chr(0), ' ')} "]

def zombie_count():
    """只统计 daemon 的子进程，避免被设备上其它僵尸干扰。"""
    rows = table()
    ds = {d["pid"] for d in daemons(rows)}
    return sum(1 for r in rows if r["state"] == "Z" and r["ppid"] in ds)

def wait_z(expected, timeout=5.0):
    end = time.time() + timeout
    last = zombie_count()
    while time.time() < end:
        last = zombie_count()
        if last == expected:
            return last
        time.sleep(0.2)
    return last

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data, method=method,
        headers={"Authorization": auth, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return {"_http": e.code, "_body": e.read().decode("utf-8", "replace")[:200]}

def unwrap(x):
    return x["data"] if isinstance(x, dict) and "data" in x else x

def api_status(method, path, body=None):
    """只要状态码：DELETE 是 204、删除后再 GET 是 404。"""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=data, method=method,
        headers={"Authorization": auth, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

def shell(cmd, timeout=None):
    body = {"command": cmd}
    if timeout is not None:
        body["timeout"] = timeout
    info = unwrap(api("POST", "/api/shell", body))
    if not isinstance(info, dict) or "id" not in info:
        return None, None
    return info["id"], info

def wait_shell(cid, timeout=40):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = unwrap(api("GET", f"/api/shell/{cid}"))
        if (last or {}).get("status") != "running":
            return last
        time.sleep(0.15)
    return last

def pty_create():
    info = unwrap(api("POST", "/api/pty", {"command": "/system/bin/sh"}))
    return info.get("id") if isinstance(info, dict) else None

print(f"  socket dir: {sock_dir}（含后缀 {len(sock_dir) + 56} 字节）")
check("socket 路径长度安全（< 104）", len(sock_dir) + 56 < 104, len(sock_dir) + 56)

# 第一条命令会拉起 daemon；必须确认它真的在跑。
cid, _ = shell("echo warmup")
if cid:
    wait_shell(cid)
    # 删掉 warmup，让 PTY 段的 Z 基线为 0（未修复版本里 DELETE 会立即 reap）。
    api("DELETE", f"/api/shell/{cid}")
    time.sleep(0.3)
for _ in range(50):
    if daemons():
        break
    time.sleep(0.2)
ds = daemons()
check(
    "opencode-pty daemon 已启动（不是 spawned fallback）",
    bool(ds),
    "daemon 没起来：多半是 socket 路径超过 SUN_LEN，或 OPENCODE_PTY_BIN 不可执行",
)
if not ds:
    sys.exit(1)
print(f"    daemon pid: {[d['pid'] for d in ds]}")
check("warmup 后 Z == 0", wait_z(0) == 0)

# 1) 50 次 PTY 创建/删除（先测，避免被 pipe 的 Z 污染）
for index in range(50):
    pid = pty_create()
    if pid:
        api("DELETE", f"/api/pty/{pid}")
    if index % 10 == 9:
        z = wait_z(0)
        check(f"PTY {index + 1}/50 后 Z == 0", z == 0, f"Z={z}")
check("PTY 50 次后 Z == 0", wait_z(0) == 0, f"Z={zombie_count()}")

# 2) 50 条混合 agent shell 命令：正常 25 / 非 0 10 / 超时 8 / 取消 7
plan = (
    [("normal", "echo normal-{}")] * 25
    + [("nonzero", "exit {}")] * 10
    + [("timeout", "sleep 30")] * 8
    + [("cancel", "sleep 30")] * 7
)
sampled = {}
for index, (kind, template) in enumerate(plan, start=1):
    if kind == "normal":
        cid, _ = shell(template.format(index))
        out = wait_shell(cid) if cid else None
        if "normal" not in sampled:
            sampled["normal"] = out
    elif kind == "nonzero":
        cid, _ = shell(template.format((index % 5) + 1))
        out = wait_shell(cid) if cid else None
        if "nonzero" not in sampled:
            sampled["nonzero"] = out
    elif kind == "timeout":
        cid, _ = shell(template, timeout=800)
        out = wait_shell(cid, timeout=40) if cid else None
        if "timeout" not in sampled:
            sampled["timeout"] = out
    else:
        cid, _ = shell(template)
        if cid:
            running = (unwrap(api("GET", f"/api/shell/{cid}")) or {}).get("status")
            deleted = api_status("DELETE", f"/api/shell/{cid}")
            time.sleep(0.3)
            after = api_status("GET", f"/api/shell/{cid}")
            if "cancel" not in sampled:
                sampled["cancel"] = {"running": running, "deleted": deleted, "after": after}
    if index % 10 == 0:
        z = wait_z(0)
        check(f"{index}/50 条后 Z == 0", z == 0, f"Z={z}")

check("50 条后 Z == 0", wait_z(0) == 0, f"Z={zombie_count()}")

# 行为回归断言
n = sampled.get("normal") or {}
check("正常命令 exit=0 且 status=exited", n.get("status") == "exited" and n.get("exit") == 0, n.get("status"))
nz = sampled.get("nonzero") or {}
check(
    "非 0 命令保留 exitCode",
    nz.get("status") == "exited" and isinstance(nz.get("exit"), int) and nz.get("exit") != 0,
    {k: nz.get(k) for k in ("status", "exit")},
)
t = sampled.get("timeout") or {}
check("超时命令 status=timeout", t.get("status") == "timeout", t.get("status"))
c = sampled.get("cancel") or {}
check(
    "取消命令：运行中 → DELETE 204 → 之后不可见",
    c.get("running") == "running" and c.get("deleted") == 204 and c.get("after") == 404,
    c,
)

# 输出分页仍然可用
marker = "oc-pty-leak-marker"
cid, _ = shell(f"echo {marker}")
if cid:
    wait_shell(cid)
    body = unwrap(api("GET", f"/api/shell/{cid}/output?cursor=0&limit=4096"))
    text = json.dumps(body, ensure_ascii=False) if body is not None else ""
    check("shell 输出可读且含标记", marker in text, text[:120])
    api("DELETE", f"/api/shell/{cid}")

# 3) 空闲后不堆积
time.sleep(10)
check("空闲 10s 后 Z == 0", wait_z(0) == 0, f"Z={zombie_count()}")

print()
if failures:
    print(f"=== 僵尸门禁失败（{len(failures)} 项）===")
    for item in failures:
        print(f"  - {item}")
    sys.exit(1)
print("=== 僵尸门禁通过 ===")
PY
