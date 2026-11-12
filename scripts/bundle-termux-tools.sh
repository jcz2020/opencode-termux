#!/usr/bin/env bash
# bundle-termux-tools.sh <runtime-stage-dir>
#
# 把 opencode agent 常用的 CLI 工具及其 Termux 依赖收进 runtime bundle：
#   usr/bin/git                 git 本体（本地 status/diff/add/commit/checkout/stash 全是 builtin）
#   usr/bin/rg                  ripgrep（opencode 的 Grep/Glob 依赖）
#   usr/libexec/git-core/...    git-remote-http(s)，HTTPS fetch/push 用
#   usr/lib/*.so*               git/rg/libcurl/openssl/pcre2 等依赖
#   usr/share/git-core/templates
#   usr/etc/tls/cert.pem        HTTPS CA bundle
#
# 所有 deb 的版本与 sha256 固定，避免上游重建后静默换二进制。下载源可换，
# 但内容必须匹配固定 sha256。BUNDLE_TOOLS=0 可跳过整个步骤。
set -euo pipefail

STAGE="${1:?usage: bundle-termux-tools.sh <runtime-stage-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/cache/termux-tools"
EXTRACT="$CACHE/extract"
STAGE_USR="$STAGE/usr"

mkdir -p "$CACHE" "$EXTRACT" "$STAGE_USR/bin" "$STAGE_USR/lib" \
         "$STAGE_USR/libexec/git-core" "$STAGE_USR/share/git-core" \
         "$STAGE_USR/etc/tls"

# 固定版本的 Termux deb。字段：包名|相对路径|sha256
PACKAGES=(
  "git|pool/main/g/git/git_2.56.1_aarch64.deb|3343f56fc99e2f0631a553a39789769495435cb07b6ffb3c71a7fcb7bd561e95"
  "ripgrep|pool/main/r/ripgrep/ripgrep_15.2.0_aarch64.deb|38e28bc297000517b24702568a483eca7dc3323eb6bdccc9033f031776bdcc6c"
  "pcre2|pool/main/p/pcre2/pcre2_10.49_aarch64.deb|c27995e5f52b8ecc9b8b3e662eb08e49f82a18bfd3f34343936acc7b23964724"
  "libcurl|pool/main/libc/libcurl/libcurl_8.23.0_aarch64.deb|2011bb9709261bb3d5ecaa6672faa333be14cf48ad4af37031e3e365309557ac"
  "libnghttp2|pool/main/libn/libnghttp2/libnghttp2_1.71.0_aarch64.deb|ae33e7b21e0636be8686b9b13a20e31267f047f69cb26b4befd70c9a9bae221e"
  "libnghttp3|pool/main/libn/libnghttp3/libnghttp3_1.19.0_aarch64.deb|8bb6fa31f9281cd48047ec9a571cadf153538f5b38f0203ad7a4e221344b14a6"
  "libngtcp2|pool/main/libn/libngtcp2/libngtcp2_1.26.0_aarch64.deb|8225ecde58104ef5aa234fa54a1bea5051a8a9ef2937e5ba996b3e8dda68c8eb"
  "libssh2|pool/main/libs/libssh2/libssh2_1.11.1-2_aarch64.deb|1add4e0a926b848814e7e2f1817ea28b123c54cabd5bbc4e5cfd65291cbad84e"
  "openssl|pool/main/o/openssl/openssl_1:3.6.5_aarch64.deb|a2fb7856875e63ef6b90442752e05974813372c3ca86d2513a78ea43c67a0f8b"
  "ca-certificates|pool/main/c/ca-certificates/ca-certificates_1:2026.11.05-1_all.deb|12fc350fc5ad638338b06b04835bce897615f8c93f96d30ac396cdb39b850c6b"
  "zlib|pool/main/z/zlib/zlib_1.4_aarch64.deb|e3027565ae50bcd8ba5113c988b589754ae192c9cc3e6afbe3e4ed7c06b2598e"
  "libexpat|pool/main/libe/libexpat/libexpat_2.10.0_aarch64.deb|0e4411f01f6fb664f3f04f9420289472f9afc30db01ea1c5d1e57fd9fa2354be"
  "libiconv|pool/main/libi/libiconv/libiconv_1.19.1_aarch64.deb|a1c6323eff4f660e16ae6f5832356444b3269c19a4f61146355a49e7c4be5ed1"
)

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

for entry in "${PACKAGES[@]}"; do
  IFS='|' read -r name rel sha <<<"$entry"
  fetch_deb "$name" "$rel" "$sha"
  rm -rf "$EXTRACT/$name"
  mkdir -p "$EXTRACT/$name"
  dpkg-deb -x "$CACHE/$name.deb" "$EXTRACT/$name"
done

echo "==> 收集 git / rg 二进制"
GIT_USR="$(find "$EXTRACT/git" -type d -path '*/files/usr' | head -1)"
RG_USR="$(find "$EXTRACT/ripgrep" -type d -path '*/files/usr' | head -1)"
[ -n "$GIT_USR" ] && [ -x "$GIT_USR/bin/git" ] || { echo "ERROR: git 包结构异常" >&2; exit 1; }
[ -n "$RG_USR" ] && [ -x "$RG_USR/bin/rg" ] || { echo "ERROR: ripgrep 包结构异常" >&2; exit 1; }

install -m 755 "$GIT_USR/bin/git" "$STAGE_USR/bin/git"
install -m 755 "$RG_USR/bin/rg" "$STAGE_USR/bin/rg"
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
for pkg in libcurl libnghttp2 libnghttp3 libngtcp2 libssh2 openssl zlib libexpat libiconv pcre2; do
  libdir="$(find "$EXTRACT/$pkg" -type d -path '*/files/usr/lib' | head -1)"
  [ -n "$libdir" ] || { echo "ERROR: $pkg 缺少 usr/lib" >&2; exit 1; }
  find "$libdir" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) \
    -exec cp -a -t "$STAGE_USR/lib" {} +
done

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

echo "==> 工具已加入 bundle："
du -sh "$STAGE_USR/bin/git" "$STAGE_USR/bin/rg" \
  "$STAGE_USR/libexec/git-core/git-remote-http" "$STAGE_USR/lib" 2>/dev/null
