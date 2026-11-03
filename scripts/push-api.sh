#!/data/data/com.termux/files/usr/bin/bash
# push-api.sh — 用 GitHub REST API 推本地提交（绕过被墙的 github.com:443）。
#
# 背景：本机 github.com 的 git-over-https 经常被 TLS RST
# （`TLS connect error: error:0A000126:SSL routines::unexpected eof while reading`），
# 但 api.github.com 一直可用。这个脚本用 Git Data API 重放提交：
#   blob（每个唯一对象一次）→ tree → commit（author/committer/message 复制）
# → 更新 ref。
#
# 注意：**远端 commit SHA 与本地不同**。GitHub 会把 author/committer 的时区
# 归一化成 UTC（本地是 +0800），commit 原始字节因此不同，SHA 必然不同；但 tree
# （文件内容）逐字节一致，本脚本结束前会断言这一点。
# 进度记在 .git/api-push-state（本地提交 SHA / 远端提交 SHA），所以不依赖
# 本地是否存在远端对象。
#
# 用法：scripts/push-api.sh [owner/repo] [branch]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
API="https://api.github.com/repos/$REPO"
TOKEN="${GH_TOKEN:-$(gh auth token)}"
STATE="$(git rev-parse --git-dir)/api-push-state"

api() {
  curl -sS --max-time 120 \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

remote_head="$(api "$API/git/ref/heads/$BRANCH" | jq -r .object.sha)"
[ -n "$remote_head" ] && [ "$remote_head" != null ] || { echo "ERROR: 取不到远端 ref" >&2; exit 1; }

# 已推到哪个本地提交（没有记录时，退化成用 origin/<branch>，可能没有）
if [ -f "$STATE" ]; then
  base_local="$(sed -n '1s/^local=//p' "$STATE")"
  base_remote="$(sed -n '2s/^remote=//p' "$STATE")"
else
  base_local="$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null || echo "")"
  base_remote="$remote_head"
fi

if [ -n "$base_local" ]; then
  mapfile -t commits < <(git rev-list --reverse "$base_local..HEAD")
else
  echo "==> 没有推送记录；本次会重放整条历史"
  mapfile -t commits < <(git rev-list --reverse "HEAD")
fi

echo "==> repo=$REPO branch=$BRANCH"
echo "    remote head = $remote_head"
echo "    已推到的本地提交 = ${base_local:-（无）}"
echo "    待推提交 = ${#commits[@]}"

if [ "${#commits[@]}" -eq 0 ]; then
  echo "OK: 没有新的提交"
  exit 0
fi

echo "==> 上传 blobs"
declare -A uploaded=()
n=0
for c in "${commits[@]}"; do
  while IFS= read -r obj; do
    [ -n "${uploaded[$obj]:-}" ] && continue
    resp="$(api -X POST "$API/git/blobs" \
      -d "$(jq -Rn --arg s "$(git cat-file -p "$obj" | base64 -w0)" \
             '{content:$s, encoding:"base64"}')")"
    sha="$(jq -r '.sha // empty' <<<"$resp")"
    [ "$sha" = "$obj" ] || { echo "ERROR: blob 上传失败: $resp" >&2; exit 1; }
    uploaded[$obj]="$sha"
    n=$((n + 1))
  done < <(git ls-tree -r "$c" | awk '{print $3}')
done
echo "    $n 个新对象"

echo "==> 重放提交"
parent="$remote_head"
for c in "${commits[@]}"; do
  tree_payload="$(git ls-tree -r "$c" \
    | jq -Rsc 'split("\n") | map(select(length > 0))
        | map(split("\t") as [$meta, $path]
              | ($meta | split(" ")) as [$mode, $type, $sha]
              | {path: $path, mode: $mode, type: "blob", sha: $sha})
        | {tree: .}')"
  tree="$(api -X POST "$API/git/trees" --data-binary "$tree_payload" | jq -r '.sha // empty')"
  [ -n "$tree" ] || { echo "ERROR: tree 创建失败" >&2; exit 1; }

  payload="$(jq -Rn \
    --arg t "$tree" --arg p "$parent" \
    --arg m "$(git log -1 --format=%B "$c")" \
    --arg an "$(git log -1 --format=%an "$c")" \
    --arg ae "$(git log -1 --format=%ae "$c")" \
    --arg ad "$(git log -1 --format=%aI "$c")" \
    --arg cn "$(git log -1 --format=%cn "$c")" \
    --arg ce "$(git log -1 --format=%ce "$c")" \
    --arg cd "$(git log -1 --format=%cI "$c")" \
    '{tree:$t, parents:[$p], message:$m,
      author:{name:$an, email:$ae, date:$ad},
      committer:{name:$cn, email:$ce, date:$cd}}')"
  new="$(api -X POST "$API/git/commits" --data-binary "$payload" | jq -r '.sha // empty')"
  [ -n "$new" ] || { echo "ERROR: commit 创建失败" >&2; exit 1; }
  echo "    $(git rev-parse --short "$c") -> ${new:0:7}"
  parent="$new"
done

resp="$(api -X PATCH "$API/git/refs/heads/$BRANCH" -d "$(jq -Rn --arg s "$parent" '{sha:$s}')")"
jq -e '.object.sha' <<<"$resp" >/dev/null || { echo "ERROR: 更新 ref 失败: $resp" >&2; exit 1; }

echo "==> 断言远端 tree == 本地 HEAD tree"
remote_tree="$(api "$API/git/commits/$parent" | jq -r .tree.sha)"
local_tree="$(git rev-parse 'HEAD^{tree}')"
[ "$remote_tree" = "$local_tree" ] || {
  echo "ERROR: tree 不一致 remote=$remote_tree local=$local_tree" >&2; exit 1; }

printf 'local=%s\nremote=%s\nbranch=%s\nrepo=%s\n' \
  "$(git rev-parse HEAD)" "$parent" "$BRANCH" "$REPO" > "$STATE"

echo "OK: 已推送 $parent（tree $local_tree 与本地一致）"
