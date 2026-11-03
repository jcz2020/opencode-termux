#!/data/data/com.termux/files/usr/bin/bash
# smoke.sh — 真 tty 冒烟：在 tmux 里起 TUI，断言渲染出来的 logo + 版本号。
# 失败退出非 0（用于 CI / 升级前自检）。
set -euo pipefail

SES="oct-smoke-$$"
SIZE="${SIZE:-110x30}"
CWD="${CWD:-$HOME}"
CMD="${1:-opencode}"
WAIT="${WAIT:-15}"

command -v tmux >/dev/null || { echo "SKIP: 无 tmux"; exit 0; }

cleanup() { tmux kill-session -t "$SES" 2>/dev/null || true; }
trap cleanup EXIT

tmux new-session -d -s "$SES" -x "${SIZE%x*}" -y "${SIZE#*x}" -c "$CWD" "$CMD"
for _ in $(seq "$WAIT"); do
  sleep 1
  if tmux capture-pane -p -t "$SES" 2>/dev/null | grep -qE 'Ask anything|New session'; then
    break
  fi
done
screen="$(tmux capture-pane -p -t "$SES" 2>/dev/null || true)"

fail() { echo "FAIL: $1"; echo "--- screen ---"; printf '%s\n' "$screen" | grep -v '^$' | head -30; exit 1; }

printf '%s\n' "$screen" | grep -qE 'Ask anything|New session' || fail "TUI 没渲染出主界面"
printf '%s\n' "$screen" | grep -qE 'Pointer exceeds safe integer' && fail "仍然命中 pointer 报错"
ver="$(printf '%s\n' "$screen" | grep -oE '2\.[0-9]+\.[0-9]+' | head -1 || true)"

echo "OK: TUI 正常渲染${ver:+（版本 $ver）}"
