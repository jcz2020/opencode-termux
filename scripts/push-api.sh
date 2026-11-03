#!/data/data/com.termux/files/usr/bin/bash
# push-api.sh — 用 GitHub REST API 推当前 HEAD（绕过被墙的 github.com:443）。
#
# 背景：本机 github.com 的 git-over-https 经常被 TLS RST
# （`TLS connect error: error:0A000126:SSL routines::unexpected eof while reading`），
# 但 api.github.com 一直可用。这个脚本用 Git Data API 重建同一个 commit：
# blob → tree → commit（author/committer/message 原样复制）→ 更新 ref。
# 若一切照原样，生成的 SHA 与本地 HEAD 完全一致，本地 origin/main 直接对齐。
#
# 用法：scripts/push-api.sh [owner/repo] [branch]
set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
SHA="$(git rev-parse HEAD)"
PARENT="$(git rev-parse HEAD^)"      # 远端 main 必须正好停在这个父提交上
MSG="$(git log -1 --format=%B HEAD)"

echo "==> repo=$REPO branch=$BRANCH sha=$SHA parent=$PARENT"
remote_head="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq .object.sha)"
echo "    remote head=$remote_head"
[ "$remote_head" = "$PARENT" ] || {
  echo "ERROR: 远端 $BRANCH=$remote_head，本地 HEAD^=$PARENT —— 不匹配。" >&2
  echo "       本脚本只做「快进一个 commit」，需要先对齐（或用 git 直连推）。" >&2
  exit 1
}

echo "==> 上传 blobs + 建 tree"
entries="[]"
while IFS=$'\t' read -r mode type obj path; do
  [ "$type" = "blob" ] || continue
  blob="$(gh api "repos/$REPO/git/blobs" -f content="$(git cat-file -p "$obj" | base64 -w0)" \
            -f encoding=base64 --jq .sha)"
  entries="$(jq -c --arg p "$path" --arg s "$blob" --arg m "$mode" \
      '. + [{path:$p, mode:$m, type:"blob", sha:$s}]' <<<"$entries")"
done < <(git ls-tree -r HEAD)

tree="$(jq -c --argjson e "$entries" '{tree: $e}' \
        | gh api "repos/$REPO/git/trees" --input - --jq .sha)"
echo "    tree=$tree"

echo "==> 建 commit（原样复制 author/committer/message）"
author="$(git log -1 --format='%an <%ae> %at %ai' HEAD | awk '{print $0}')"
aname="$(git log -1 --format=%an)"; amail="$(git log -1 --format=%ae)"; adate="$(git log -1 --format=%aI)"
cname="$(git log -1 --format=%cn)"; cmail="$(git log -1 --format=%ce)"; cdate="$(git log -1 --format=%cI)"
body="$(jq -Rn --arg t "$tree" --arg p "$PARENT" --arg m "$MSG" \
        --arg an "$aname" --arg ae "$amail" --arg ad "$adate" \
        --arg cn "$cname" --arg ce "$cmail" --arg cd "$cdate" \
        '{tree:$t, parents:[$p], message:$m,
          author:{name:$an, email:$ae, date:$ad},
          committer:{name:$cn, email:$ce, date:$cd}}')"
new="$(gh api "repos/$REPO/git/commits" --input - --jq .sha <<<"$body")"
echo "    commit=$new"

echo "==> 更新 refs/heads/$BRANCH"
gh api -X PATCH "repos/$REPO/git/refs/heads/$BRANCH" -f sha="$new" --jq '.object.sha' >/dev/null
git update-ref "refs/remotes/origin/$BRANCH" "$new"

if [ "$new" = "$SHA" ]; then
  echo "OK: 远端已与本地 HEAD 一致（$new）"
else
  echo "WARN: 远端 commit $new != 本地 HEAD $SHA（tree 一致，元数据有差）"
  echo "      本地 origin/$BRANCH 已指向远端提交，后续 push 前可能需要 rebase。"
fi
