#!/data/data/com.termux/files/usr/bin/bash
# smoke-pty.sh — 验证 opencode-pty 持久 PTY daemon 能在 Android/Termux 启动。
#
# 2.3.0 的 opencode 会通过 PATH 找 opencode-pty；daemon 默认用 /tmp 放 socket，
# Android 上 /tmp 不可写，所以 wrapper/App 必须注入 OPENCODE_PTY_SOCKET_DIR。
set -euo pipefail

BIN="${OPENCODE_PTY_BIN:-$(command -v opencode-pty || true)}"
[ -n "$BIN" ] && [ -x "$BIN" ] || { echo "SKIP: 没装 opencode-pty"; exit 0; }

echo "==> opencode-pty version"
"$BIN" --version

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-pty.XXXXXX" 2>/dev/null || mktemp -d)"
cleanup() {
  "$BIN" stop --name smoke --runtime-dir "$TMP/pty" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/pty"
SOCK="${TMPDIR:-$HOME/tmp}/opty-$$"
mkdir -p "$SOCK"
export OPENCODE_PTY_SOCKET_DIR="$SOCK"

echo "==> start daemon"
"$BIN" daemon --name smoke --runtime-dir "$TMP/pty" >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!

ok=false
for _ in $(seq 10); do
  sleep 1
  if "$BIN" status --name smoke --runtime-dir "$TMP/pty" >"$TMP/status.log" 2>&1 \
     && grep -q 'opencode-pty running' "$TMP/status.log"; then
    ok=true
    break
  fi
done
if [ "$ok" != "true" ]; then
  echo "FAIL: opencode-pty daemon 没起来" >&2
  cat "$TMP/daemon.log" >&2 || true
  cat "$TMP/status.log" >&2 || true
  exit 1
fi

echo "==> stop daemon"
"$BIN" stop --name smoke --runtime-dir "$TMP/pty" >/dev/null 2>&1 || true
wait "$DAEMON_PID" 2>/dev/null || true
echo "OK: opencode-pty daemon 可启动/停止"
