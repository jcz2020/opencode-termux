#!/data/data/com.termux/files/usr/bin/bash
# smoke-release.sh [tag] — 在 Termux 设备上做真机冒烟。
#
#   1. 从 GitHub release 下载 deb（github.com 不通时走 asset API）
#   2. dpkg -i 安装
#   3. tmux 真 tty 起 TUI，断言主界面渲染 + 版本号
#   4. 顺便验一下 shell 工具能跑（bun-pty 那条链）
#
# 用法：bash scripts/smoke-release.sh [v2.2.5+termux2]
# 不带 tag 时用 release 里最新的那个。
set -euo pipefail

REPO="${REPO:-jcz2020/opencode-termux}"
TAG="${1:-}"
WORK="$HOME/tmp/smoke-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

command -v tmux >/dev/null || { echo "SKIP: 没装 tmux"; exit 0; }
command -v dpkg >/dev/null || { echo "SKIP: 没装 dpkg"; exit 0; }

# ── 1. 找 release ───────────────────────────────────────────────
if [ -z "$TAG" ]; then
  TAG="$(curl -sS --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" \
    | jq -r .tag_name)"
  [ -n "$TAG" ] && [ "$TAG" != null ] || { echo "ERROR: 取不到最新 release" >&2; exit 1; }
fi
echo "==> release: $TAG"

ASSET_NAME="$(curl -sS --max-time 30 "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
  | jq -r '.assets[] | select(.name | endswith(".deb")) | .name' | head -1)"
[ -n "$ASSET_NAME" ] || { echo "ERROR: release $TAG 里没有 .deb" >&2; exit 1; }

# ── 2. 下载（github.com 不通 → asset API） ───────────────────────
echo "==> 下载 $ASSET_NAME"
ASSET_ID="$(curl -sS --max-time 30 "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
  | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name == $n) | .id')"
AUTH=()
[ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: token $GH_TOKEN")
# 本机到 github.com/api.github.com 偶发 TLS EOF → 带重试
for i in 1 2 3 4 5; do
  if curl -sSL --max-time 900 "${AUTH[@]}" -H 'Accept: application/octet-stream' \
       -o "$WORK/$ASSET_NAME.part" \
       "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID"; then
    mv "$WORK/$ASSET_NAME.part" "$WORK/$ASSET_NAME"; break
  fi
  echo "    下载失败，重试 $i"; sleep 5
done
[ -f "$WORK/$ASSET_NAME" ] || { echo "ERROR: 下载失败" >&2; exit 1; }
ls -la "$WORK/$ASSET_NAME"

echo "==> sha256"
sha256sum "$WORK/$ASSET_NAME"

# ── 3. 安装 ──────────────────────────────────────────────────────
echo "==> dpkg -i"
dpkg -i "$WORK/$ASSET_NAME" 2>&1 | tail -3
echo "    opencode --version → $(opencode --version)"

# ── 4. TUI 冒烟（tmux 真 tty） ─────────────────────────────────
SES="smoke-release-$$"
SIZE="${SIZE:-110x34}"
CWD="${CWD:-$HOME}"
cleanup() { tmux kill-session -t "$SES" 2>/dev/null || true; }
trap 'cleanup; rm -rf "$WORK"' EXIT

echo "==> tmux 起 TUI"
tmux new-session -d -s "$SES" -x "${SIZE%x*}" -y "${SIZE#*x}" -c "$CWD" opencode
ok=0
for _ in $(seq 25); do
  sleep 1
  screen="$(tmux capture-pane -p -t "$SES" 2>/dev/null || true)"
  if grep -qE 'Ask anything|New session' <<<"$screen"; then ok=1; break; fi
done
screen="$(tmux capture-pane -p -t "$SES" 2>/dev/null || true)"

fail() { echo "FAIL: $1"; echo "--- screen ---"; grep -v '^$' <<<"$screen" | head -30; exit 1; }

[ "$ok" = 1 ] || fail "TUI 没渲染出主界面"
grep -qE 'Pointer exceeds safe integer' <<<"$screen" && fail "仍然命中 pointer 报错"
ver="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$screen" | tail -1 || true)"
echo "OK: TUI 正常渲染${ver:+（版本 $ver）}"

# ── 5. shell 工具（bun-pty 那条链） ─────────────────────────────
echo "==> 验 shell 工具（bun-pty）"
if command -v python3 >/dev/null; then
  python3 -c 'import pty,sys; pty.spawn(["/data/data/com.termux/files/usr/bin/sh","-c","echo PTY-OK"])' \
    2>/dev/null | grep -q 'PTY-OK' \
    && echo "OK: pty 可用" \
    || echo "WARN: pty 自检没通过（不影响 TUI）"
else
  echo "SKIP: 没装 python3，跳过 pty 自检"
fi

echo
echo "=== 设备冒烟通过（$TAG）==="
