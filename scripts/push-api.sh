#!/data/data/com.termux/files/usr/bin/bash
# push-api.sh — 用 GitHub REST API 推本地提交（绕过被墙的 github.com:443）。
#
# 背景：本机 github.com 的 git-over-https 经常被 TLS RST
# （`TLS connect error: error:0A000126:SSL routines::unexpected eof while reading`），
# 但 api.github.com 一直可用。这个脚本用 Git Data API 逐个重放 commit：
#   blob（每个唯一对象一次）→ tree → commit（author/committer/message 原样复制）
# → 最后更新 ref。git 与 GitHub 的 blob sha 算法相同，所以内容一样的对象
# 重放后 SHA 也一致，本地 origin/<branch> 可以直接对齐。
#
# 用法：scripts/push-api.sh [owner/repo] [branch]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"

remote_head="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
mapfile -t commits < <(git rev-list --reverse "$remote_head..HEAD")
[ "${#commits[@]}" -gt 0 ] || { echo "==> 没有要推的提交（本地已在 $remote_head）"; exit 0; }

echo "==> repo=$REPO branch=$BRANCH"
echo "    remote head = $remote_head"
echo "    待推提交    = ${#commits[@]}"

echo "==> 上传所需 blobs"
declare -A seen=()
for c in "${commits[@]}"; do
  while IFS=$'\t' read -r mode type obj path; do
    [ "$type" = "blob" ] || continue
    [ -n "${seen[$obj]:-}" ] && continue
    seen[$obj]="$(gh api "repos/$REPO/git/blobs" \
      -f content="$(git cat-file -p "$obj" | base64 -w0)" \
      -f encoding=base64 --jq .sha)"
  done < <(git ls-tree -r "$c")
done
echo "    ${#seen[@]} 个对象"

echo "==> 逐个重放 commit"
parent="$remote_head"
for c in "${commits[@]}"; do
  entries="[]"
  while IFS=$'\t' read -r mode type obj path; do
    [ "$type" = "blob" ] || continue
    entries="$(jq -c --arg p "$path" --arg s "${seen[$obj]}" --arg m "$mode" \
      '. + [{path:$p, mode:$m, type:"blob", sha:$s}]' <<<"$entries")"
  done < <(git ls-tree -r "$c")

  tree="$(jq -c --argjson e "$entries" '{tree: $e}' \
          | gh api "repos/$REPO/git/trees" --input - --jq .sha)"

  body="$(jq -Rn --arg t "$tree" --arg p "$parent" \
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
  new="$(gh api "repos/$REPO/git/commits" --input - --jq .sha <<<"$body")"

  local_short="$(git rev-parse --short "$c")"
  if [ "$new" = "$c" ]; then
    echo "    $local_short ✓ 重放一致"
  else
    echo "    $local_short -> $new ⚠ 元数据有差（tree 相同）"
  fi
  parent="$new"
done

echo "==> 更新 refs/heads/$BRANCH -> $parent"
gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" -f sha="$parent" --jq '.object.sha' >/dev/null
git update-ref "refs/remotes/origin/$BRANCH" "$parent"

if [ "$parent" = "$(git rev-parse HEAD)" ]; then
  echo "OK: 远端与本地 HEAD 完全一致（$parent）"
else
  echo "WARN: 远端 HEAD=$parent != 本地 $(git rev-parse HEAD)"
  echo "      tree 一致，只是 committer 元数据不同；origin/$BRANCH 已对齐远端。"
fi
