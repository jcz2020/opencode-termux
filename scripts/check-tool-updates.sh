#!/usr/bin/env bash
# check-tool-updates.sh — 对比 scripts/termux-tools.lock 与 Termux 仓库索引。
#
# 退出码：
#   0  全部与 lock 一致
#   2  有可用更新（或 lock 里的包已从索引消失）
#   1  网络/解析错误
#
# 用法：
#   bash scripts/check-tool-updates.sh
#   bash scripts/check-tool-updates.sh --packages-file /path/to/Packages
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/termux-tools.lock"
MIRRORS=(
  "https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages"
  "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main/dists/stable/main/binary-aarch64/Packages"
  "https://mirrors.bfsu.edu.cn/termux/apt/termux-main/dists/stable/main/binary-aarch64/Packages"
)

PACKAGES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --packages-file)
      PACKAGES_FILE="${2:?--packages-file 需要路径}"; shift 2 ;;
    --help|-h)
      echo "usage: $0 [--packages-file FILE]"; exit 0 ;;
    *)
      echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -f "$LOCK" ] || { echo "ERROR: 缺少 $LOCK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-tools.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$PACKAGES_FILE" ]; then
  PACKAGES_FILE="$TMP/Packages"
  ok=false
  for url in "${MIRRORS[@]}"; do
    echo "==> 拉取 $url" >&2
    if curl -fsSL --retry 2 --retry-all-errors -m 90 -o "$PACKAGES_FILE" "$url"; then
      ok=true
      break
    fi
  done
  [ "$ok" = "true" ] || { echo "ERROR: 无法拉取 Termux Packages 索引" >&2; exit 1; }
fi

[ -s "$PACKAGES_FILE" ] || { echo "ERROR: Packages 索引为空" >&2; exit 1; }

field() {
  local pkg="$1" key="$2"
  awk -v pkg="$pkg" -v key="$key" '
    BEGIN { RS = ""; FS = "\n" }
    $0 ~ ("^Package: " pkg "(\\n|$)") {
      for (i = 1; i <= NF; i++) {
        if ($i ~ ("^" key ": ")) {
          sub("^" key ": ", "", $i)
          print $i
          exit
        }
      }
    }
  ' "$PACKAGES_FILE"
}

is_newer() {
  local pinned="$1" available="$2"
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$available" gt "$pinned"
  else
    [ "$available" != "$pinned" ] && [ "$(printf '%s\n%s\n' "$pinned" "$available" | sort -V | tail -1)" = "$available" ]
  fi
}

updates=0
missing=0
table=""
notes=""

while IFS='|' read -r name pinned rel sha; do
  case "$name" in
    ""|\#*) continue ;;
  esac
  [ -n "$pinned" ] && [ -n "$rel" ] && [ -n "$sha" ] || {
    echo "ERROR: termux-tools.lock 行格式错误: $name|$pinned|$rel|$sha" >&2
    exit 1
  }

  available="$(field "$name" Version)"
  if [ -z "$available" ]; then
    missing=$((missing + 1))
    notes+="- **$name**: lock 里的 $pinned 已不在当前索引（可能被上游移除）"$'\n'
    continue
  fi

  if is_newer "$pinned" "$available"; then
    updates=$((updates + 1))
    table+="| $name | $pinned | $available |"$'\n'
  else
    echo "  OK   $name $pinned" >&2
  fi
done < "$LOCK"

if [ "$updates" -eq 0 ] && [ "$missing" -eq 0 ]; then
  echo "All pinned Termux tools are up to date."
  exit 0
fi

cat <<EOF
## Termux CLI tools update available

对比文件：\`scripts/termux-tools.lock\`

| Package | Pinned | Available |
|---|---|---|
${table}${notes}
更新流程：

1. 修改 \`scripts/termux-tools.lock\` 的版本/路径/sha256；
2. 跑 \`make smoke-static\` 和 \`make check-16kb\`（或完整 \`make source-deb\`）；
3. 验证 \`make smoke\` / \`make smoke-service\`；
4. 发新的 \`+termuxN\` 修订，不要覆盖已有 release；
5. 跑 \`make publish-tool-cache\` 缓存本次 lock 的 deb。
EOF

exit 2
