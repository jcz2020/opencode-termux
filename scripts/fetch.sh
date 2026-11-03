#!/data/data/com.termux/files/usr/bin/bash
# fetch.sh <version> — 取上游 opencode aarch64 包到 cache/，并校验 sha256。
#
# 来源：Hope2333/opencode-termux 的 release 资产（bionic 原生构建）。
# 本机 github.com 直连不可用，但 api.github.com + objects.githubusercontent.com 通，
# 所以统一走 asset API（返回 302 到签名 URL），不碰 github.com。
#
# 兼容：也可以手动把 opencode-<ver>-1-aarch64.pkg.tar.xz 丢进 cache/ 再跑本脚本，
# 校验照跑（.MTREE 里的 sha256digest）。
set -euo pipefail

VER="${1:-}"
[ -n "$VER" ] || { echo "usage: fetch.sh <version>   e.g. fetch.sh 2.2.5" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/cache"
ASSET="opencode-${VER}-1-aarch64.pkg.tar.xz"
PKG="$CACHE/$ASSET"
REPO="${REPO:-Hope2333/opencode-termux}"

mkdir -p "$CACHE"

if [ ! -f "$PKG" ]; then
  echo "==> 查找资产 $ASSET (repo=$REPO)"
  meta_auth=()
  [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && meta_auth=(-H "Authorization: token ${GH_TOKEN:-$GITHUB_TOKEN}")
  asset_id="$(curl -sS --max-time 30 "${meta_auth[@]}" \
      "https://api.github.com/repos/$REPO/releases?per_page=10" \
    | jq -r --arg n "$ASSET" \
      '[.[].assets[] | select(.name == $n)] | first | .id // empty')"
  [ -n "$asset_id" ] || { echo "ERROR: 最近 10 个 release 里没有 $ASSET" >&2; exit 1; }
  echo "==> 下载 asset id=$asset_id"
  auth=()
  [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && auth=(-H "Authorization: token ${GH_TOKEN:-$GITHUB_TOKEN}")
  curl -sSL --max-time 900 -H 'Accept: application/octet-stream' "${auth[@]}" \
    -o "$PKG.part" "https://api.github.com/repos/$REPO/releases/assets/$asset_id"
  mv "$PKG.part" "$PKG"
fi

echo "==> 校验 .MTREE 里的 sha256"
want="$(tar -xOf "$PKG" .MTREE | gzip -dc | tr '\0' '\n' \
        | grep 'usr/bin/opencode ' | grep -oE 'sha256digest=[a-f0-9]+' | cut -d= -f2)"
[ -n "$want" ] || { echo "ERROR: .MTREE 里找不到 bin/opencode 摘要" >&2; exit 1; }
have="$(tar -xOf "$PKG" data/data/com.termux/files/usr/bin/opencode | sha256sum | cut -d' ' -f1)"
[ "$want" = "$have" ] || { echo "ERROR: sha256 不符 want=$want have=$have" >&2; exit 1; }
echo "    ok $have"
echo "==> cache ready: $PKG"
