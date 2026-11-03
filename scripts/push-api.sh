#!/data/data/com.termux/files/usr/bin/bash
# push-api.sh — 用 GitHub REST API 推本地提交（绕过被墙的 github.com:443）。
#
# 背景：本机 github.com 的 git-over-https 经常被 TLS RST
# （`TLS connect error: error:0A000126:SSL routines::unexpected eof while reading`），
# 但 api.github.com 一直可用。这个脚本用 Git Data API 逐个重放 commit：
#   blob（每个唯一对象一次）→ tree → commit（author/committer/message 原样复制）
# → 最后更新 ref。git 与 GitHub 的 blob sha 算法相同，内容一致则 SHA 一致，
# 所以本地 origin/<branch> 可以直接对齐。
#
# 用法：scripts/push-api.sh [owner/repo] [branch]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
API="https://api.github.com/repos/$REPO"
TOKEN="${GH_TOKEN:-$(gh auth token)}"

api() {  # api <curl args...>
  curl -sS --max-time 120 \
    -H "Authorization: token $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

remote_head="$(api "$API/git/ref/heads/$BRANCH" | jq -r .object.sha)"
mapfile -t commits < <(git rev-list --reverse "$remote_head..HEAD")
[ "${#commits[@]}" -gt 0 ] || { echo "==> 没有要推的提交（远端已是 $remote_head）"; exit 0; }

echo "==> repo=$REPO branch=$BRANCH"
echo "    remote head = $remote_head"
echo "    待推提交    = ${#commits[@]}"

# 1) 每个唯一 blob 上传一次
declare -A uploaded=()
upload_count=0
for c in "${commits[@]}"; do
  while IFS= read -r obj; do
    [ -n "${uploaded[$obj]:-}" ] && continue
    resp="$(api -X POST "$API/git/blobs" \
      -d "$(jq -Rn --arg s "$(git cat-file -p "$obj" | base64 -w0)" \
             '{content:$s, encoding:"base64"}')")"
    sha="$(jq -r '.sha // empty' <<<"$resp")"
    [ -n "$sha" ] || { echo "ERROR: blob 上传失败: $resp" >&2; exit 1; }
    [ "$sha" = "$obj" ] || { echo "ERROR: blob sha 不符 $obj -> $sha" >&2; exit 1; }
    uploaded[$obj]="$sha"
    upload_count=$((upload_count + 1))
  done < <(git ls-tree -r "$c" | awk '{print $3}')
done
echo "    blobs: $upload_count"

# 2) 逐个 commit 重放
parent="$remote_head"
for c in "${commits[@]}"; do
  tree_payload="$(git ls-tree -r "$c" \
    | jq -Rsc 'split("\n") | map(select(length > 0))
        | map(split("\t") as [$meta, $path]
              | ($meta | split(" ")) as [$mode, $type, $sha]
              | {path: $path, mode: $mode, type: "blob", sha: $sha})
        | {tree: .}')"
  tree="$(api -X POST "$API/git/trees" --data-binary "$tree_payload" | jq -r '.sha // empty')"
  [ -n "$tree" ] || { echo "ERROR: tree 创建失败: $tree_payload" >&2; exit 1; }

  commit_payload="$(jq -Rn \
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
  new="$(api -X POST "$API/git/commits" --data-binary "$commit_payload" | jq -r '.sha // empty')"
  [ -n "$new" ] || { echo "ERROR: commit 创建失败" >&2; exit 1; }

  if [ "$new" = "$c" ]; then
    echo "    $(git rev-parse --short "$c") ✓ 重放一致"
  else
    echo "    $(git rev-parse --short "$c") -> $new ⚠ 元数据有差（tree 相同）"
  fi
  parent="$new"
done

# 3) 更新 ref + 对齐本地 remote-tracking
resp="$(api -X PATCH "$API/git/refs/heads/$BRANCH" -d "$(jq -Rn --arg s "$parent" '{sha:$s}')")"
jq -e '.object.sha' <<<"$resp" >/dev/null || { echo "ERROR: 更新 ref 失败: $resp" >&2; exit 1; }
git update-ref "refs/remotes/origin/$BRANCH" "$parent"
echo "==> refs/heads/$BRANCH -> $parent"

if [ "$parent" = "$(git rev-parse HEAD)" ]; then
  echo "OK: 远端与本地 HEAD 完全一致"
else
  echo "WARN: 远端 HEAD=$parent != 本地 $(git rev-parse HEAD)（tree 一致，仅元数据不同）"
fi
