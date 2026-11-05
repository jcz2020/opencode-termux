#!/data/data/com.termux/files/usr/bin/bash
# e2e-scenarios.sh — 在沙箱目录里跑一组高价值交互场景，验证源码线的 opencode
# 除了"能渲染"之外还能真的干活。
#
# 用法：bash scripts/e2e-scenarios.sh [sandbox-dir]
# 绝不在项目目录里跑（会改文件）。
set -uo pipefail

SANDBOX="${1:-$HOME/tmp/oc-sandbox}"
WORK="$SANDBOX/.e2e"
SESSION="e2e-$$"
PASS=0; FAIL=0

rm -rf "$WORK"; mkdir -p "$WORK/sub"
printf 'line1\nline2\nline3\n' > "$WORK/small.txt"
printf 'def greet(name):\n    return f"hello {name}"\n' > "$WORK/greet.py"
python3 - "$WORK/big.txt" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(20000):
        f.write("row %d: %s\n" % (i, "x" * 40))
PY

cleanup() { tmux kill-session -t "$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

ask() {  # ask <prompt> <expect-regex> <label>
  local prompt="$1" expect="$2" label="$3"
  cleanup
  tmux new-session -d -s "$SESSION" -x 110 -y 34 -c "$WORK" opencode
  sleep 12
  tmux send-keys -t "$SESSION" -l "$prompt"
  tmux send-keys -t "$SESSION" Enter
  local got=0
  for _ in $(seq 45); do
    sleep 2
    local scr; scr="$(tmux capture-pane -p -t "$SESSION" 2>/dev/null || true)"
    grep -qE "$expect" <<<"$scr" && { got=1; break; }
    grep -qiE 'crashed|Missing OpenTUI|InvalidArgument|Internal Server Error' <<<"$scr" && break
  done
  local scr; scr="$(tmux capture-pane -p -t "$SESSION" 2>/dev/null || true)"
  if [ "$got" = 1 ]; then
    echo "PASS  $label"; PASS=$((PASS+1)); return 0
  fi
  echo "FAIL  $label"
  grep -v '^$' <<<"$scr" | tail -20 | sed 's/^/      /'
  FAIL=$((FAIL+1)); return 1
}

echo "==> 沙箱：$WORK"
echo

ask 'read the file small.txt and reply with exactly: SMALL=line2' 'SMALL=line2' \
    '读小文件'
ask 'use the bash tool to run: wc -l big.txt   then reply with exactly: BIGLINES=20000' 'BIGLINES=20000' \
    '跑命令读大文件行数'
ask 'use the bash tool to run: grep -c "row 19999" big.txt   then reply with exactly: GREP=1' 'GREP=1' \
    'grep 大文件'
ask 'use the edit tool to change greet.py so it returns "hi <name>" instead of "hello <name>". then reply with exactly: EDITED' 'EDITED' \
    '编辑文件'
ask 'create a file named made.txt containing the single word OK. then reply with exactly: CREATED' 'CREATED' \
    '新建文件'
ask 'use the bash tool to run: sleep 3 && echo LONG-DONE   then reply with exactly: SAW=LONG-DONE' 'SAW=LONG-DONE' \
    '长命令等输出'

echo
echo "==> 校验文件真的被改了"
if grep -q 'hi {name}' "$WORK/greet.py" 2>/dev/null; then
  echo "PASS  greet.py 内容确实改了"; PASS=$((PASS+1))
else
  echo "FAIL  greet.py 内容没改（模型说改了但没落盘）"; FAIL=$((FAIL+1))
  grep -n . "$WORK/greet.py" 2>/dev/null | sed 's/^/      /'
fi
if [ -f "$WORK/made.txt" ] && grep -q OK "$WORK/made.txt" 2>/dev/null; then
  echo "PASS  made.txt 真的建出来了"; PASS=$((PASS+1))
else
  echo "FAIL  made.txt 没建出来"; FAIL=$((FAIL+1))
fi

echo
echo "=== 通过 $PASS / 失败 $FAIL ==="
[ "$FAIL" = 0 ] || exit 1
