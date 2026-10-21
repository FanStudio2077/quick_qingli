#!/usr/bin/env bash
# qingli 一行安装引导脚本
#
#   curl -fsSL https://raw.githubusercontent.com/FanStudio2077/quick_qingli/main/get.sh | sudo bash
#   curl -fsSL .../get.sh | sudo bash -s -- --root /data --bin /path/to/qingli
#
# 它做两件事：
#   1) 下载脚本包（install.sh + deploy/ 单元与 ctl）到临时目录；
#   2) 确定 qingli 二进制：
#        - 参数里有 --bin / 设了 QINGLI_BIN  → 直接用；
#        - 否则尝试从本仓库 GitHub Releases 下载 qingli-linux-<arch>；
#        - 都没有 → 明确报错并告诉你该怎么办。
#   然后把其余参数原样交给 install.sh。
#
# 为什么要引导脚本：curl 只能取单个文件，而 install.sh 需要同目录的 deploy/。
set -euo pipefail

OWNER=FanStudio2077
REPO=quick_qingli
BRANCH=${QL_BRANCH:-main}

C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_INFO=$'\033[36m'; C_OFF=$'\033[0m'
say() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
die() { printf '%s  ✗%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：curl ... | sudo bash"

# 需要 curl 或 wget 之一
if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fsSL --max-time 120 "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q -T 120 -O "$2" "$1"; }
else
    die "需要 curl 或 wget"
fi

TMP=$(mktemp -d /tmp/qingli-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# ---------------- 参数里是否已经有 --bin ----------------
# 注意：这里只判断"用户显式传了 --bin"，不要把 QINGLI_BIN 也算进来，
# 否则会跳过下面的 QINGLI_BIN → --bin 追加逻辑（实测踩过：装了却报"缺少源码"）。
has_bin_arg=0
prev=""
for a in "$@"; do
    [[ "$a" == "--bin" || "$a" == --bin=* ]] && has_bin_arg=1
    [[ "$prev" == "--bin" ]] && has_bin_arg=1
    prev="$a"
done

# ---------------- 下载脚本包 ----------------
say "下载脚本包（$OWNER/$REPO@$BRANCH）"
TARBALL="$TMP/pkg.tar.gz"
fetch "https://github.com/$OWNER/$REPO/archive/refs/heads/$BRANCH.tar.gz" "$TARBALL" \
    || die "下载失败：请检查网络，或改用
    git clone https://github.com/$OWNER/$REPO.git && cd $REPO && sudo bash install.sh ..."
tar xzf "$TARBALL" -C "$TMP" || die "解包失败"
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
            *) die "不支持的架构: $arch" ;;
        esac
        url="https://github.com/$OWNER/$REPO/releases/latest/download/qingli-linux-$arch"
        say "尝试从 Releases 下载二进制（qingli-linux-$arch）"
        if fetch "$url" "$TMP/qingli" 2>/dev/null; then
            chmod +x "$TMP/qingli"
            extra_args+=(--bin "$TMP/qingli")
        else
            die "没有找到可用的 qingli 二进制。
   本仓库只含安装脚本，二进制需要你提供：
     方式一（推荐）：把编译好的 qingli 放到服务器上，然后
       curl -fsSL https://raw.githubusercontent.com/$OWNER/$REPO/$BRANCH/get.sh | sudo bash -s -- --bin /path/to/qingli
     方式二：发布一个 Release，附件名 qingli-linux-$arch，之后即可真正一键安装。
     方式三：从源码构建后本地安装（仓库根目录执行）
       cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
       sudo bash install.sh --bin build/qingli"
        fi
    fi
fi

# ---------------- 交给 install.sh ----------------
say "运行安装器"
exec bash "$SRC/install.sh" "${extra_args[@]}" "$@"
