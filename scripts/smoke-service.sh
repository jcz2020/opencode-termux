#!/data/data/com.termux/files/usr/bin/bash
# smoke-service.sh — 验证 2.3.0 的「后台服务常驻 + 客户端连接」启动链路。
#
# 2.3.0 的 TUI 会用 process.execPath 重新执行 `serve --service`。如果 wrapper
# 把 execPath 变成 /system/bin/linker64，服务会报：
#   error: expected absolute path: "serve"
# 本脚本用隔离的 XDG_STATE_HOME 启一个独立服务，验证 wrapper 能正确拉起它。
set -euo pipefail

command -v opencode >/dev/null || { echo "SKIP: 没装 opencode"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: 没装 python3"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-service.XXXXXX" 2>/dev/null || mktemp -d)"
mkdir -p "$TMP/home" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache"

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

cleanup() {
  iso timeout 20 opencode service stop >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> service set port $PORT"
if ! iso opencode service set port "$PORT" >"$TMP/set.log" 2>&1; then
  echo "FAIL: service set port 失败" >&2
  cat "$TMP/set.log" >&2
  exit 1
fi

echo "==> service start"
if ! iso timeout 60 opencode service start >"$TMP/start.log" 2>&1; then
  echo "FAIL: service start 失败" >&2
  cat "$TMP/start.log" >&2
  exit 1
fi

if grep -qE 'expected absolute path|Server process exited|linker64' "$TMP/start.log"; then
  echo "FAIL: service 启动日志命中 execPath/linker64 错误" >&2
  cat "$TMP/start.log" >&2
  exit 1
fi

echo "==> service status"
if ! iso timeout 20 opencode service status >"$TMP/status.log" 2>&1; then
  echo "FAIL: service status 失败" >&2
  cat "$TMP/status.log" >&2
  exit 1
fi
grep -q "127.0.0.1:$PORT" "$TMP/status.log" || {
  echo "FAIL: service status 没显示预期端口 $PORT" >&2
  cat "$TMP/status.log" >&2
  exit 1
}

echo "OK: 后台服务可由 wrapper 独立拉起（port $PORT）"
