#!/usr/bin/env bash
# publish-tool-cache.sh — 把当前 lock 对应的全部 Termux deb 打成内容寻址缓存，
# 上传到独立的 toolchain-cache release，供以后旧 deb 被 Termux 删除时重建使用。
#
# 资产名：termux-tools-<lock sha256>.tar.zst
# 上传目标：<repo>/releases/tag/toolchain-cache
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/termux-tools.lock"
CACHE="$ROOT/cache/termux-tools"
REPO="${GITHUB_REPOSITORY:-jcz2020/opencode-termux}"
TAG="${TOOL_CACHE_TAG:-toolchain-cache}"

[ -f "$LOCK" ] || { echo "ERROR: 缺少 $LOCK" >&2; exit 1; }
command -v gh >/dev/null || { echo "ERROR: 需要 gh CLI" >&2; exit 1; }
command -v zstd >/dev/null || { echo "ERROR: 需要 zstd" >&2; exit 1; }

LOCK_SHA="$(sha256sum "$LOCK" | awk '{print $1}')"
ASSET="termux-tools-${LOCK_SHA}.tar.zst"

TMP="$(mktemp -d "${TMPDIR:-$HOME/tmp}/oc-toolcache.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 复用 bundle 脚本的下载/校验逻辑；它会把 deb 放进 cache/termux-tools。
echo "==> 准备当前 lock 的 deb"
bash "$ROOT/scripts/bundle-termux-tools.sh" "$TMP/stage" >/dev/null

mkdir -p "$TMP/debs"
while IFS='|' read -r name version rel sha; do
  case "$name" in
    ""|\#*) continue ;;
  esac
  [ -f "$CACHE/$name.deb" ] || { echo "ERROR: 缺少 $name.deb" >&2; exit 1; }
  cp "$CACHE/$name.deb" "$TMP/debs/$name.deb"
done < "$LOCK"

echo "==> 打包 $ASSET"
# 固定 mtime/owner/排序，让同一 lock 的缓存 tar 可复现。
tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
  -cf - -C "$TMP/debs" . | zstd -19 -T0 -f -o "$TMP/$ASSET"
CACHE_SHA="$(sha256sum "$TMP/$ASSET" | awk '{print $1}')"
echo "    $CACHE_SHA  $ASSET"
echo "    $(du -h "$TMP/$ASSET" | cut -f1)"

if ! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "==> 创建缓存 release: $TAG"
  gh release create "$TAG" -R "$REPO" \
    --title "Termux tool cache" \
    --notes "内容寻址的 Termux CLI 工具 deb 缓存。资产名带 lock sha256，不要删除仍在使用的快照。" \
    --latest=false
fi

if gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name' | grep -qxF "$ASSET"; then
  echo "==> 缓存资产已存在，跳过上传: $ASSET"
else
  echo "==> 上传缓存资产: $ASSET"
  gh release upload "$TAG" "$TMP/$ASSET" -R "$REPO"
fi

echo "DONE: https://github.com/$REPO/releases/download/$TAG/$ASSET"
