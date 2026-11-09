#!/data/data/com.termux/files/usr/bin/bash
# install-termux.sh — OpenCode for Termux/aarch64 一键安装与升级脚本
#
# 特性：
#   * 大陆网络自动多镜像加速（对齐 opencode-app 候选源），自动测速与故障切换
#   * 支持断点续传与 SHA-256 完整性严格校验
#   * 自动选定数学版本号最高（SemVer 排序）的兼容 +termux Release
#   * 支持重复执行作为升级工具（新装与升级同一入口）
#   * 支持 --check（仅检查更新）、--force（强制重装/降级）、--dry-run
#
# 用法：
#   curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/jcz2020/opencode-termux/main/scripts/install-termux.sh | bash
#   或本地直接运行：bash scripts/install-termux.sh [--check] [--force]
set -euo pipefail

REPO="jcz2020/opencode-termux"
PREFIX_DIR="/data/data/com.termux/files/usr"
MIRRORS=(
  "https://ghfast.top/"
  "https://ghproxy.cn/"
  "https://gh-proxy.com/"
  "https://ghproxy.net/"
)

# ── 1. 参数解析 ──────────────────────────────────────────────
CHECK_ONLY=false
FORCE_INSTALL=false
DRY_RUN=false
TARGET_VER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check|-c)
      CHECK_ONLY=true; shift ;;
    --force|-f)
      FORCE_INSTALL=true; shift ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --version|-v)
      TARGET_VER="$2"; shift 2 ;;
    --help|-h)
      echo "用法: $0 [选项]"
      echo "选项:"
      echo "  --check, -c       只检查是否有新版本，不执行下载与安装"
      echo "  --force, -f       强制下载并覆盖安装当前或指定版本"
      echo "  --version, -v VER 安装指定版本（如 2.2.6+termux1 或 2.2.6）"
      echo "  --dry-run         显示拟执行的下载与版本信息，不做改动"
      echo "  --help, -h        显示本帮助信息"
      exit 0
      ;;
    *)
      # 若首参数非选项，视作目标版本
      if [ -z "$TARGET_VER" ]; then
        TARGET_VER="$1"; shift
      else
        echo "未知参数: $1" >&2; exit 1
      fi
      ;;
  esac
done

# ── 2. 环境自检 ──────────────────────────────────────────────
if [ ! -d "$PREFIX_DIR" ] && [ -z "${PREFIX:-}" ]; then
  echo "ERROR: 本脚本专用于 Termux (Android) 环境。" >&2
  echo "       检测到非 Termux 路径: $PREFIX_DIR 不存在。" >&2
  exit 1
fi

ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [ "$ARCH" != "aarch64" ]; then
  echo "ERROR: 本项目目前仅支持 aarch64 (ARM64) 架构，当前设备为 $ARCH。" >&2
  exit 1
fi

# 确保基础依赖存在
ensure_dep() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "==> 安装必要依赖: $pkg..."
    pkg install -y "$pkg" >/dev/null 2>&1 || apt-get install -y "$pkg"
  fi
}

ensure_dep curl curl
ensure_dep jq jq
ensure_dep dpkg dpkg

# ── 3. 大陆网络感知与加速候选生成 ─────────────────────────────
is_mainland_china() {
  if [ -n "${OPENCODE_FORCE_CHINA:-}" ]; then
    return 0
  fi
  if [ -n "${OPENCODE_FORCE_GLOBAL:-}" ]; then
    return 1
  fi
  # A. SIM / 移动网络 MCC 检测（460 开头为中国大陆运营商）
  if command -v getprop >/dev/null 2>&1; then
    local sim_mcc; sim_mcc="$(getprop gsm.sim.operator.numeric 2>/dev/null || true)"
    local net_mcc; net_mcc="$(getprop gsm.operator.numeric 2>/dev/null || true)"
    if [[ "$sim_mcc" =~ ^460 ]] || [[ "$net_mcc" =~ ^460 ]]; then
      return 0
    fi
    local loc; loc="$(getprop persist.sys.locale 2>/dev/null || getprop ro.product.locale 2>/dev/null || true)"
    if [[ "$loc" =~ (zh-CN|CN) ]]; then
      return 0
    fi
  fi
  # B. LANG 环境变量
  if [[ "${LANG:-}" =~ (zh_CN|zh-CN) ]]; then
    return 0
  fi
  # C. 极速探测：若直连 github.com 握手超时则判定需要镜像
  if ! curl -sI -m 2 https://github.com >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

resolve_candidates() {
  local orig="$1"
  local list=()
  if is_mainland_china; then
    for m in "${MIRRORS[@]}"; do
      list+=("${m}${orig}")
    done
    list+=("$orig")
  else
    list+=("$orig")
    for m in "${MIRRORS[@]}"; do
      list+=("${m}${orig}")
    done
  fi
  printf '%s\n' "${list[@]}"
}

# ── 4. 版本比对辅助 ──────────────────────────────────────────
ver_compare() {
  local v1="$1"
  local v2="$2"
  if [ "$v1" = "$v2" ]; then
    echo "eq"
    return 0
  fi
  local highest
  highest=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | tail -1)
  if [ "$highest" = "$v1" ]; then
    echo "gt"
  else
    echo "lt"
  fi
}

get_installed_version() {
  local ver=""
  if command -v dpkg-query >/dev/null 2>&1; then
    ver="$(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true)"
  fi
  if [ -z "$ver" ] && command -v opencode >/dev/null 2>&1; then
    ver="$(opencode --version 2>/dev/null | awk '{print $2}' | sed 's/^v//' || true)"
  fi
  echo "$ver"
}

# ── 5. 解析最新兼容 Release ──────────────────────────────────
resolve_target_release() {
  local target="$1"
  if [ -n "$target" ]; then
    # 若用户指定了版本
    target="${target#v}"
    if [[ ! "$target" =~ \+termux[0-9]+$ ]]; then
      target="${target}+termux1"
    fi
    echo "$target"
    return 0
  fi

  # 策略 1: 走 GitHub API 获取所有 release，按 SemVer 严格选最大的 +termux 版本
  local api_url="https://api.github.com/repos/$REPO/releases?per_page=30"
  local json_raw=""
  json_raw="$(curl -sSL -m 8 -H 'Accept: application/vnd.github.v3+json' "$api_url" 2>/dev/null || true)"

  if [ -n "$json_raw" ] && [ "$json_raw" != "null" ]; then
    local best_tag
    best_tag="$(echo "$json_raw" | jq -r '.[].tag_name // empty' 2>/dev/null \
      | grep -oE '^v[0-9]+\.[0-9]+\.[0-9]+\+termux[0-9]+$' \
      | sort -V | tail -1 || true)"
    if [ -n "$best_tag" ]; then
      echo "${best_tag#v}"
      return 0
    fi
  fi

  # 策略 2: API 失败时，走镜像拉取 runtime-manifest.json 兜底
  local manifest_orig="https://github.com/$REPO/releases/latest/download/runtime-manifest.json"
  while IFS= read -r cand; do
    local m_content
    m_content="$(curl -sSL -m 6 "$cand" 2>/dev/null || true)"
    if [ -n "$m_content" ]; then
      local m_ver
      m_ver="$(echo "$m_content" | jq -r '.version // empty' 2>/dev/null || true)"
      if [ -n "$m_ver" ]; then
        echo "${m_ver#v}"
        return 0
      fi
    fi
  done < <(resolve_candidates "$manifest_orig")

  echo ""
}

# ── 6. 多通道断点续传与校验下载器 ───────────────────────────
is_valid_deb_header() {
  local file="$1"
  [ -f "$file" ] || return 1
  local magic
  magic="$(head -c 8 "$file" 2>/dev/null || true)"
  if [ "$magic" = "!<arch>"$'\n' ] || [ "$magic" = "!<arch>" ]; then
    return 0
  fi
  return 1
}

download_file() {
  local target="$1"
  local expected_sha="$2"
  local is_deb="${3:-false}"
  shift 3
  local candidates=("$@")

  for cand in "${candidates[@]}"; do
    echo "  -> 尝试通道: $cand"
    local resume_opts=()
    if [ -s "$target" ]; then
      resume_opts=("-C" "-")
    fi

    # 使用 --http1.1 规避部分反向代理对长连接大文件 HTTP/2 reset 问题
    local progress_opt=("--progress-bar")
    [ -t 1 ] || progress_opt=("-sS")

    if curl -fSL "${resume_opts[@]}" "${progress_opt[@]}" --http1.1 --connect-timeout 8 --max-time 600 -o "$target" "$cand" 2>/dev/null; then
      # 如果下载的是 deb，检查是否以 !<arch> 开头（避免代理返回 HTML 验证码页）
      if [ "$is_deb" = "true" ] && ! is_valid_deb_header "$target"; then
        echo "  ⚠ 下载内容非合法 deb 归档（疑似镜像验证码/拦截页），丢弃并切换通道..."
        rm -f "$target"
        continue
      fi

      if [ -n "$expected_sha" ]; then
        local actual_sha
        actual_sha="$(sha256sum "$target" 2>/dev/null | awk '{print $1}')"
        if [ "$actual_sha" = "$expected_sha" ]; then
          echo "  ✓ 校验通过: $actual_sha"
          return 0
        else
          echo "  ⚠ SHA-256 校验不匹配（期望 $expected_sha，实际 $actual_sha），丢弃残片换下一通道..."
          rm -f "$target"
        fi
      else
        return 0
      fi
    else
      echo "  ✗ 该通道下载中断或超时，切换备选通道..."
      # 若文件非合法归档，清理残片以便下一通道干净重试
      if [ "$is_deb" = "true" ] && [ -f "$target" ] && ! is_valid_deb_header "$target"; then
        rm -f "$target"
      fi
    fi
  done
  return 1
}

# ── 7. 主执行逻辑 ────────────────────────────────────────────
INSTALLED_VER="$(get_installed_version)"
TARGET_RELEASE="$(resolve_target_release "$TARGET_VER")"

if [ -z "$TARGET_RELEASE" ]; then
  echo "ERROR: 无法解析最新版本信息。请检查网络后重试。" >&2
  exit 1
fi

TAG="v${TARGET_RELEASE}"
DEB_NAME="opencode_${TARGET_RELEASE}_aarch64.deb"
SHA_NAME="${DEB_NAME}.sha256"

echo "=============================================================="
echo " OpenCode Termux 安装/更新程序"
echo "=============================================================="
echo "  当前安装版本: ${INSTALLED_VER:-未安装}"
echo "  目标可用版本: $TARGET_RELEASE ($TAG)"
if is_mainland_china; then
  echo "  网络环境判定: 中国大陆 (已自动启用加速镜像与多源重试)"
else
  echo "  网络环境判定: 全球/海外 (直连优先，镜像兜底)"
fi
echo "=============================================================="

if [ "$CHECK_ONLY" = "true" ]; then
  if [ -n "$INSTALLED_VER" ]; then
    cmp_res="$(ver_compare "$INSTALLED_VER" "$TARGET_RELEASE")"
    if [ "$cmp_res" = "eq" ]; then
      echo "✓ 已是最新版本 ($INSTALLED_VER)，无需更新。"
      exit 0
    elif [ "$cmp_res" = "gt" ]; then
      echo "✓ 当前安装版本 ($INSTALLED_VER) 高于线上稳定版 ($TARGET_RELEASE)。"
      exit 0
    else
      echo "★ 发现新版本: $TARGET_RELEASE（当前: $INSTALLED_VER）"
      echo "  运行 'opencode update' 或重新执行安装命令即可升级。"
      exit 0
    fi
  else
    echo "★ 尚未安装 OpenCode，可安装版本: $TARGET_RELEASE"
    exit 0
  fi
fi

if [ -n "$INSTALLED_VER" ] && [ "$FORCE_INSTALL" != "true" ]; then
  cmp_res="$(ver_compare "$INSTALLED_VER" "$TARGET_RELEASE")"
  if [ "$cmp_res" = "eq" ]; then
    echo "✓ OpenCode 当前已是最新版本 (v$INSTALLED_VER)，无需重复安装。"
    echo "  若需强制重装，请带 --force 参数。"
    exit 0
  elif [ "$cmp_res" = "gt" ]; then
    echo "✓ 本地版本 (v$INSTALLED_VER) 高于线上版本 (v$TARGET_RELEASE)，无需更新。"
    echo "  若需强制降级，请带 --force 参数。"
    exit 0
  else
    echo "==> 检测到新版本，开始更新: v$INSTALLED_VER -> v$TARGET_RELEASE"
  fi
else
  echo "==> 开始安装 OpenCode v$TARGET_RELEASE"
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "[dry-run] 拟下载资产: $DEB_NAME"
  exit 0
fi

TMP_DIR="$(mktemp -d "${PREFIX_DIR}/tmp/opencode-install.XXXXXX" 2>/dev/null || mktemp -d "/tmp/opencode-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DEB_LOCAL="$TMP_DIR/$DEB_NAME"
SHA_LOCAL="$TMP_DIR/$SHA_NAME"

# A. 下载校验和文件
SHA_ORIG_URL="https://github.com/$REPO/releases/download/$TAG/$SHA_NAME"
mapfile -t SHA_CANDIDATES < <(resolve_candidates "$SHA_ORIG_URL")

echo "==> [1/3] 获取安装包哈希校验信息..."
EXPECTED_SHA=""
if download_file "$SHA_LOCAL" "" false "${SHA_CANDIDATES[@]}"; then
  EXPECTED_SHA="$(awk '{print $1}' "$SHA_LOCAL" | head -1 || true)"
  echo "  目标包预期 SHA-256: $EXPECTED_SHA"
else
  echo "  WARN: 无法单独获取 sha256 文件，将依赖安装时校验。"
fi

# B. 下载 deb 安装包（多通道加速 + 断点续传）
DEB_ORIG_URL="https://github.com/$REPO/releases/download/$TAG/$DEB_NAME"
mapfile -t DEB_CANDIDATES < <(resolve_candidates "$DEB_ORIG_URL")

echo "==> [2/3] 下载安装包 ($DEB_NAME)..."
if ! download_file "$DEB_LOCAL" "$EXPECTED_SHA" true "${DEB_CANDIDATES[@]}"; then
  echo "ERROR: 所有下载通道均失败。请检查网络连接后重试。" >&2
  exit 1
fi

# C. 安装 dpkg 包
echo "==> [3/3] 安装 deb 包 (dpkg -i)..."
dpkg -i "$DEB_LOCAL"

# 刷新 hash 缓存
hash -r 2>/dev/null || true

echo "=============================================================="
echo "✓ OpenCode 安装/升级完成！"
NEW_VER="$(get_installed_version)"
echo "  当前版本: ${NEW_VER:-$TARGET_RELEASE}"
echo ""
echo "快速开始："
echo "  opencode          # 启动终端交互界面 (TUI)"
echo "  opencode serve    # 启动网页端服务 (Web UI 模式)"
echo "  opencode update   # 检查并更新到本项目的最新版本"
echo "=============================================================="
