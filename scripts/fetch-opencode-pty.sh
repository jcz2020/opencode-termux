#!/usr/bin/env bash
# fetch-opencode-pty.sh <destination> — 取固定版本的 opencode-pty 静态二进制。
#
# 上游 npm 包 @opencode/pty-linux-arm64-musl 是 statically linked aarch64
# Linux 可执行文件，可直接在 Android/Termux 上运行。版本/URL/sha256 在
# scripts/opencode-pty.lock 中固定。
set -euo pipefail

DEST="${1:?usage: fetch-opencode-pty.sh <destination>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/opencode-pty.lock"
CACHE="$ROOT/cache/opencode-pty"

[ -f "$LOCK" ] || { echo "ERROR: 缺少 $LOCK" >&2; exit 1; }

line="$(grep -v '^[[:space:]]*#' "$LOCK" | grep -v '^[[:space:]]*$' | head -1)"
IFS='|' read -r name version pkg url sha <<<"$line"
[ -n "$name" ] && [ -n "$version" ] && [ -n "$url" ] && [ -n "$sha" ] || {
  echo "ERROR: opencode-pty.lock 格式错误" >&2; exit 1
}

mkdir -p "$CACHE"
TARBALL="$CACHE/${name}-${version}.tgz"

verify() {
  local file="$1"
  [ -f "$file" ] || return 1
  [ "$(sha256sum "$file" | awk '{print $1}')" = "$sha" ]
}

if ! verify "$TARBALL"; then
  rm -f "$TARBALL"
  mirror="${url/registry.npmjs.org/registry.npmmirror.com}"
  ok=false
  for u in "$url" "$mirror"; do
    echo "    下载 $name $version: $u"
    if curl -fsSL --retry 2 --retry-all-errors -m 120 -o "$TARBALL.tmp" "$u"; then
      if verify "$TARBALL.tmp"; then
        mv "$TARBALL.tmp" "$TARBALL"
        ok=true
        break
      fi
      echo "    WARN: sha256 不匹配，换源" >&2
      rm -f "$TARBALL.tmp"
    fi
  done
  [ "$ok" = "true" ] || { echo "ERROR: 无法下载或校验 $name $version" >&2; exit 1; }
fi

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-opencode-pty.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$TARBALL" -C "$TMP"
BIN="$TMP/package/bin/opencode-pty"
[ -f "$BIN" ] || { echo "ERROR: npm 包里没有 package/bin/opencode-pty" >&2; exit 1; }
install -m 755 "$BIN" "$DEST"
echo "    $name $version -> $DEST"
