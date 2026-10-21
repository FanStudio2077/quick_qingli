#!/usr/bin/env bash
# qingli 一行安装引导脚本
#
#   curl -fsSL https://raw.githubusercontent.com/FanStudio2077/quick_qingli/main/get.sh | sudo bash
#   curl -fsSL .../get.sh | sudo bash -s -- --root /data --bin /path/to/qingli
#
# 它做三件事：
#   1) **自动选下载通道**：并发探测直连与若干 GitHub 镜像，取响应最快的一个；
#      单个通道失败会自动换下一个重试（不会因为某个镜像挂了就装不了）。
#   2) 下载脚本包（install.sh + deploy/）到临时目录。
#   3) 确定 qingli 二进制：--bin 参数 > QINGLI_BIN 环境变量 > Release 附件。
#      都没有时给出明确指引。
#
# 环境变量：
#   QL_MIRROR=https://gh-proxy.org/   强制指定镜像前缀（跳过自动探测）
#   QL_NO_MIRROR=1                    只用直连，不探测镜像
#   QL_PROBE_TIMEOUT=5                单通道探测超时（秒）
#   QINGLI_BIN=/path/to/qingli        指定二进制
#   QL_BRANCH=main                    改用其他分支
set -euo pipefail

OWNER=FanStudio2077
REPO=quick_qingli
BRANCH=${QL_BRANCH:-main}
PROBE_TIMEOUT=${QL_PROBE_TIMEOUT:-5}

C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_WARN=$'\033[33m'; C_INFO=$'\033[36m'; C_DIM=$'\033[2m'
C_OFF=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s  ✗%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：curl ... | sudo bash"

# ---------------- 下载工具 ----------------
if command -v curl >/dev/null 2>&1; then
    DL=curl
    # -f 失败即报错，-L 跟随重定向（Release 附件会 302 到 CDN），--retry 抗抖动
    fetch() { curl -fsSL --retry 1 --connect-timeout 8 --max-time 300 "$1" -o "$2"; }
    probe() { curl -fsSL --connect-timeout 4 --max-time "$PROBE_TIMEOUT" -o /dev/null "$1"; }
elif command -v wget >/dev/null 2>&1; then
    DL=wget
    fetch() { wget -q -T 300 -O "$2" "$1"; }
    probe() { wget -q -T "$PROBE_TIMEOUT" --spider "$1"; }
else
    die "需要 curl 或 wget"
fi

TMP=$(mktemp -d /tmp/qingli-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---------------- 通道（镜像）自动选择 ----------------
# 约定：镜像是"前缀"，把原始 GitHub URL 整段接在后面，例如
#   https://gh-proxy.org/https://github.com/owner/repo/archive/...tar.gz
# 空字符串代表直连。
MIRRORS=(
    ""                        # 直连
    "https://gh-proxy.org/"   # 镜像
    "https://ghfast.top/"     # 镜像
    "https://ghproxy.net/"    # 镜像
    "https://gh-proxy.com/"   # 镜像
)

RAW_URL="https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/get.sh"

# 探测一个通道，成功则把 "毫秒 前缀" 写入 $2
probe_one() {
    local prefix="$1" out="$2" t0 t1
    t0=$(date +%s%N 2>/dev/null || echo 0)
    if probe "${prefix}${RAW_URL}" 2>/dev/null; then
        t1=$(date +%s%N 2>/dev/null || echo 0)
        local ms=0
        [[ "$t0" != "0" && "$t1" != "0" ]] && ms=$(( (t1 - t0) / 1000000 ))
        printf '%s\t%s\n' "$ms" "$prefix" > "$out"
    fi
}

pick_mirror() {
    # 显式指定优先（必须同时写入 CHOSEN，否则下面 fetch_any 会忽略它）
    if [[ -n "${QL_MIRROR:-}" ]]; then
        [[ "$QL_MIRROR" == */ ]] || QL_MIRROR="$QL_MIRROR/"
        CHOSEN="$QL_MIRROR"
        say "使用指定通道：$QL_MIRROR"
        return 0
    fi
    if [[ "${QL_NO_MIRROR:-0}" == "1" ]]; then
        CHOSEN=""
        say "已禁用镜像探测（QL_NO_MIRROR=1），使用直连"
        return 0
    fi

    say "探测下载通道（1 个直连 + $(( ${#MIRRORS[@]} - 1 )) 个镜像，${PROBE_TIMEOUT}s 超时）"
    local dir="$TMP/probe"
    mkdir -p "$dir"
    local i=0 p
    for p in "${MIRRORS[@]}"; do
        probe_one "$p" "$dir/$i" &
        i=$((i + 1))
    done
    wait || true

    local best_ms="" best="" ms prefix f
    for f in "$dir"/*; do
        [[ -f "$f" ]] || continue
        IFS=$'\t' read -r ms prefix < "$f"
        [[ -n "$ms" ]] || continue
        if [[ -z "$best_ms" ]] || (( ms < best_ms )); then
            best_ms=$ms; best=$prefix
        fi
    done

    if [[ -z "$best_ms" ]]; then
        warn "所有通道探测失败，仍先尝试直连；如果卡住请设置 QL_MIRROR"
        CHOSEN=""
        return 0
    fi

    CHOSEN=$best
    if [[ -z "$best" ]]; then
        say "通道：直连（${best_ms} ms）"
    else
        say "通道：${best}（${best_ms} ms）"
        printf '%s  注意：这是第三方代理，下载的二进制建议用 sha256 核对%s\n' "$C_DIM" "$C_OFF"
    fi
}

# 带失败回退的下载：先用选中通道，失败再依次试其它通道
fetch_any() {
    local url="$1" out="$2" seen=" " p
    local order=("${CHOSEN:-}" "" "${MIRRORS[@]}")
    for p in "${order[@]}"; do
        case "$seen" in *"|$p|"*) continue ;; esac
        seen="$seen|$p|"
        if fetch "${p}${url}" "$out" 2>/dev/null; then
            if [[ -n "$p" && "$p" != "${CHOSEN:-}" ]]; then
                warn "选中通道不可用，已回退到：${p:-直连}"
            fi
            return 0
        fi
    done
    return 1
}

# ---------------- 参数里是否已经有 --bin ----------------
# 只判断"用户显式传了 --bin"，不要把 QINGLI_BIN 算进来，
# 否则会跳过下面的 QINGLI_BIN → --bin 追加（实测踩过）。
has_bin_arg=0
prev=""
for a in "$@"; do
    [[ "$a" == "--bin" || "$a" == --bin=* ]] && has_bin_arg=1
    [[ "$prev" == "--bin" ]] && has_bin_arg=1
    prev="$a"
done

CHOSEN=""
pick_mirror

# ---------------- 下载脚本包 ----------------
TARBALL="$TMP/pkg.tar.gz"
TARBALL_URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$BRANCH.tar.gz"
say "下载脚本包（$OWNER/$REPO@$BRANCH）"
fetch_any "$TARBALL_URL" "$TARBALL" || die "脚本包下载失败：所有通道都不可用。
   请检查网络，或手动执行：
     git clone https://github.com/$OWNER/$REPO.git && cd $REPO && sudo bash install.sh ..."

tar xzf "$TARBALL" -C "$TMP" || die "解包失败（下载内容可能被代理截断，可换一个通道重试）"
SRC="$TMP/$REPO-$BRANCH"
[[ -f "$SRC/install.sh" ]] || die "脚本包不完整（缺少 install.sh）"

# ---------------- 解析二进制 ----------------
extra_args=()
if [[ $has_bin_arg -eq 0 ]]; then
    if [[ -n "${QINGLI_BIN:-}" ]]; then
        extra_args+=(--bin "$QINGLI_BIN")
        say "使用 QINGLI_BIN=$QINGLI_BIN"
    else
        arch=$(uname -m)
        case "$arch" in
            x86_64|aarch64) ;;
            *) die "不支持的架构: $arch（可自行构建后加 --bin）" ;;
        esac
        url="https://github.com/$OWNER/$REPO/releases/latest/download/qingli-linux-$arch"
        say "尝试从 Releases 下载二进制（qingli-linux-$arch）"
        if fetch_any "$url" "$TMP/qingli" && [[ -s "$TMP/qingli" ]]; then
            chmod +x "$TMP/qingli"
            extra_args+=(--bin "$TMP/qingli")
        else
            die "没有找到可用的 qingli 二进制。
   本仓库只含安装脚本，二进制需要你提供：
     方式一（推荐）：把编译好的 qingli 放到服务器上，然后
       curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/get.sh | sudo bash -s -- --bin /path/to/qingli
     方式二：发布 Release，附件名 qingli-linux-$arch，之后即可真正一键安装。
     方式三：从源码构建后本地安装（仓库根目录执行）
       cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
       sudo bash install.sh --bin build/qingli"
        fi
    fi
fi

# ---------------- 交给 install.sh ----------------
say "运行安装器"
exec bash "$SRC/install.sh" "${extra_args[@]}" "$@"
