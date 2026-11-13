#!/usr/bin/env bash
# bundle-termux-tools.sh <runtime-stage-dir>
#
# 把 opencode agent 常用的 CLI 工具及其 Termux 依赖收进 runtime bundle：
#   usr/bin/git                 git 本体（本地 status/diff/add/commit/checkout/stash 全是 builtin）
#   usr/bin/rg                  ripgrep（opencode 的 Grep/Glob 依赖）
#   usr/bin/gh / fd / jq        常用开发 CLI
#   usr/bin/busybox             常用 shell 工具集
#   usr/libexec/git-core/...    git-remote-http(s)，HTTPS fetch/push 用
#   usr/lib/*.so*               git/rg/libcurl/openssl/pcre2 等依赖
#   usr/share/git-core/templates
#   usr/etc/tls/cert.pem        HTTPS CA bundle
#
# 所有 deb 的版本与 sha256 固定，避免上游重建后静默换二进制。下载源可换，
# 但内容必须匹配固定 sha256。BUNDLE_TOOLS=0 可跳过整个步骤。
#
# 版本源在 scripts/termux-tools.lock（name|version|path|sha256）。
# 要加 gh/fd/jq/busybox 等工具时：
#   1. 在 lock 里加固定版本 + sha256；
#   2. 在“收集 git / rg 二进制”段把 ELF 复制到 $STAGE_USR/bin；
#   3. App 侧 prepare-jnilibs.sh 会自动把 usr/bin 下的 ELF 收进 jniLibs。
set -euo pipefail

STAGE="${1:?usage: bundle-termux-tools.sh <runtime-stage-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/termux-tools.lock"
CACHE="$ROOT/cache/termux-tools"
EXTRACT="$CACHE/extract"
STAGE_USR="$STAGE/usr"

[ -f "$LOCK" ] || { echo "ERROR: 缺少 $LOCK" >&2; exit 1; }

mkdir -p "$CACHE" "$EXTRACT" "$STAGE_USR/bin" "$STAGE_USR/lib" \
         "$STAGE_USR/libexec/git-core" "$STAGE_USR/share/git-core" \
         "$STAGE_USR/etc/tls"

MIRRORS=(
  "https://packages.termux.dev/apt/termux-main"
  "https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
  "https://mirrors.bfsu.edu.cn/termux/apt/termux-main"
)

verify_sha() {
  local file="$1" want="$2"
  [ -f "$file" ] || return 1
  local have
  have="$(sha256sum "$file" | awk '{print $1}')"
  [ "$have" = "$want" ]
}

fetch_deb() {
  local name="$1" rel="$2" sha="$3"
  local out="$CACHE/$name.deb"
  if verify_sha "$out" "$sha"; then
    return 0
  fi
  rm -f "$out" "$out.tmp"
  local base
  for base in "${MIRRORS[@]}"; do
    echo "    下载 $name: $base/$rel"
    if curl -fSL --retry 2 --retry-all-errors -m 300 -o "$out.tmp" "$base/$rel"; then
      if verify_sha "$out.tmp" "$sha"; then
        mv "$out.tmp" "$out"
        return 0
      fi
      echo "    WARN: sha256 不匹配，换源" >&2
      rm -f "$out.tmp"
    fi
  done
  echo "ERROR: 无法下载或校验 $name ($rel)" >&2
  return 1
}

pkg_count=0
while IFS='|' read -r name version rel sha; do
  case "$name" in
    ""|\#*) continue ;;
  esac
  [ -n "$version" ] && [ -n "$rel" ] && [ -n "$sha" ] || {
    echo "ERROR: termux-tools.lock 行格式错误: $name|$version|$rel|$sha" >&2
    exit 1
  }
  echo "==> $name $version"
  fetch_deb "$name" "$rel" "$sha"
  rm -rf "$EXTRACT/$name"
  mkdir -p "$EXTRACT/$name"
  dpkg-deb -x "$CACHE/$name.deb" "$EXTRACT/$name"
  pkg_count=$((pkg_count + 1))
done < "$LOCK"

[ "$pkg_count" -gt 0 ] || { echo "ERROR: termux-tools.lock 没有有效包" >&2; exit 1; }
echo "    已准备 $pkg_count 个 Termux 包"

echo "==> 收集 CLI 二进制"
GIT_USR="$(find "$EXTRACT/git" -type d -path '*/files/usr' | head -1)"
RG_USR="$(find "$EXTRACT/ripgrep" -type d -path '*/files/usr' | head -1)"
GH_USR="$(find "$EXTRACT/gh" -type d -path '*/files/usr' | head -1)"
FD_USR="$(find "$EXTRACT/fd" -type d -path '*/files/usr' | head -1)"
JQ_USR="$(find "$EXTRACT/jq" -type d -path '*/files/usr' | head -1)"
BB_USR="$(find "$EXTRACT/busybox" -type d -path '*/files/usr' | head -1)"
for pair in "git:$GIT_USR" "ripgrep:$RG_USR" "gh:$GH_USR" "fd:$FD_USR" "jq:$JQ_USR" "busybox:$BB_USR"; do
  label="${pair%%:*}"
  usr="${pair#*:}"
  [ -n "$usr" ] && [ -d "$usr/bin" ] || { echo "ERROR: $label 包结构异常" >&2; exit 1; }
done

install -m 755 "$GIT_USR/bin/git" "$STAGE_USR/bin/git"
install -m 755 "$RG_USR/bin/rg" "$STAGE_USR/bin/rg"
install -m 755 "$GH_USR/bin/gh" "$STAGE_USR/bin/gh"
install -m 755 "$FD_USR/bin/fd" "$STAGE_USR/bin/fd"
install -m 755 "$JQ_USR/bin/jq" "$STAGE_USR/bin/jq"
install -m 755 "$BB_USR/bin/busybox" "$STAGE_USR/bin/busybox"
install -m 755 "$GIT_USR/libexec/git-core/git-remote-http" \
  "$STAGE_USR/libexec/git-core/git-remote-http"

# git-core 里的 builtin 大多是 ../../bin/git 的符号链接；全部保留，
# 只额外带 git-remote-http 这一个真实 helper（其余真实的 send-email 等不需要）。
find "$GIT_USR/libexec/git-core" -maxdepth 1 -type l \
  -exec cp -a -t "$STAGE_USR/libexec/git-core" {} +
ln -sfn git-remote-http "$STAGE_USR/libexec/git-core/git-remote-https"

# init 需要模板；status/diff 不需要，但带上只有 80 KB。
cp -a "$GIT_USR/share/git-core/templates" "$STAGE_USR/share/git-core/"

echo "==> 收集依赖 .so"
while IFS= read -r libdir; do
  find "$libdir" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a -t "$STAGE_USR/lib" {} +
done < <(find "$EXTRACT" -type d -path '*/files/usr/lib' | sort)

# HTTPS 证书。libcurl/openssl 默认路径是 Termux prefix，App 运行时会用
# GIT_SSL_CAINFO 指到这里。
CERT="$(find "$EXTRACT/ca-certificates" -type f -path '*/usr/etc/tls/cert.pem' | head -1)"
[ -n "$CERT" ] || { echo "ERROR: ca-certificates 缺少 cert.pem" >&2; exit 1; }
cp -a "$CERT" "$STAGE_USR/etc/tls/cert.pem"
OPENSSL_CNF="$(find "$EXTRACT/openssl" -type f -path '*/usr/etc/tls/openssl.cnf' | head -1)"
[ -n "$OPENSSL_CNF" ] && cp -a "$OPENSSL_CNF" "$STAGE_USR/etc/tls/openssl.cnf"

# 统一权限（Termux 的 deb 内文件可能是 700）
chmod 755 "$STAGE_USR/bin/git" "$STAGE_USR/bin/rg" \
  "$STAGE_USR/libexec/git-core/git-remote-http"
find "$STAGE_USR/libexec/git-core" -maxdepth 1 -type f -exec chmod 755 {} +
find "$STAGE_USR/lib" -maxdepth 1 -type f -name '*.so*' -exec chmod 644 {} +
find "$STAGE_USR/share/git-core" -type d -exec chmod 755 {} +
find "$STAGE_USR/share/git-core" -type f -exec chmod 644 {} +
chmod 644 "$STAGE_USR/etc/tls/cert.pem"
[ -f "$STAGE_USR/etc/tls/openssl.cnf" ] && chmod 644 "$STAGE_USR/etc/tls/openssl.cnf"

mkdir -p "$STAGE_USR/licenses"
cat > "$STAGE_USR/licenses/THIRD-PARTY-TOOLS.md" <<'NOTICE'
# Bundled CLI tools

These binaries are built by the Termux project and distributed unmodified:

- git 2.56.1 — GNU General Public License v2.0
  https://github.com/git/git
- ripgrep 15.2.0 — MIT / Unlicense
  https://github.com/BurntSushi/ripgrep
- gh 2.104.0 — MIT License
  https://github.com/cli/cli
- fd 10.5.2 — MIT / Apache-2.0
  https://github.com/sharkdp/fd
- jq 1.8.2 — MIT License
  https://github.com/jqlang/jq
- oniguruma 6.9.10 — BSD 2-Clause
  https://github.com/kkos/oniguruma
- busybox 1.38.0 — GNU General Public License v2.0
  https://busybox.net
- libandroid-selinux — Apache License 2.0
  https://github.com/termux/libandroid-selinux
- PCRE2 10.49 — BSD 3-Clause
  https://github.com/PCRE2Project/pcre2
- libcurl 8.23.0 — curl License
  https://github.com/curl/curl
- OpenSSL 3.6.5 — Apache License 2.0
  https://github.com/openssl/openssl
- zlib, libexpat, libiconv, libssh2, nghttp2/nghttp3/ngtcp2
  zlib / MIT / LGPL / BSD-style licenses
- ca-certificates — Mozilla Public License 2.0

Termux package sources and build recipes:
  https://github.com/termux/termux-packages
NOTICE
chmod 644 "$STAGE_USR/licenses/THIRD-PARTY-TOOLS.md"

echo "==> 工具已加入 bundle："
du -sh "$STAGE_USR/bin/git" "$STAGE_USR/bin/rg" "$STAGE_USR/bin/gh" \
  "$STAGE_USR/bin/fd" "$STAGE_USR/bin/jq" "$STAGE_USR/bin/busybox" \
  "$STAGE_USR/libexec/git-core/git-remote-http" "$STAGE_USR/lib" 2>/dev/null
