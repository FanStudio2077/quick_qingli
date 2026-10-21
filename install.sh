#!/usr/bin/env bash
# qingli 一键安装 / 卸载
#
#   sudo ./install.sh                    # 自动选最大真实挂载点作为扫描根
#   sudo ./install.sh --root /data       # 指定扫描根
#   sudo ./install.sh --port 9000        # 指定 Web 端口（被占用会自动顺延）
#   sudo ./install.sh --bin ./build/qingli   # 用已编译好的二进制，跳过构建
#                                             # （仅含脚本的仓库必须用这种方式）
#   sudo ./install.sh --no-first-scan    # 装完不立即首扫（默认会立刻跑一次）
#   sudo ./install.sh --uninstall        # 停止并移除服务与二进制（保留数据）
#   sudo ./install.sh --uninstall --purge # 连库与配置一起删
#
# 设计原则：
#   - 幂等：重复执行等于升级，**不会**覆盖已有的访问令牌与端口配置（除非 --force）。
#   - 无 systemd 的环境（容器/部分 WSL）不会失败：照常安装文件，只是不 enable/start。
#   - 扫描根用"自动选最大真实挂载点"时要排除伪文件系统与只读挂载，
#     否则会把 /proc、/sys、squashfs 快照之类算进去。
set -euo pipefail

BIN_DST=/usr/local/bin/qingli
ETC_DIR=/etc/qingli
LIB_DIR=/var/lib/qingli
UNIT_DIR=/etc/systemd/system
CTL_DST=/usr/local/bin/qingli-ctl
CONF="$ETC_DIR/install.conf"
WEB_ENV="$ETC_DIR/web.env"

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_OVERRIDE=""
PORT_OVERRIDE=""
BIN_SRC=""
FIRST_SCAN=1
UNINSTALL=0
PURGE=0
FORCE=0

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_info=$'\033[36m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s  !%s %s\n' "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%s  ✗%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root) ROOT_OVERRIDE=${2:-}; shift 2 ;;
        --port) PORT_OVERRIDE=${2:-}; shift 2 ;;
        --bin)  BIN_SRC=${2:-}; shift 2 ;;
        --no-first-scan) FIRST_SCAN=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge) PURGE=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "请用 root 运行（sudo ./install.sh）"

have_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }
sysd_do() {
    if have_systemd; then systemctl "$@" || warn "systemctl $* 未成功（继续）"
    else warn "本机没有运行 systemd，跳过 systemctl $*"; fi
}

# ---------------------------------------------------------------- 卸载
if [[ $UNINSTALL -eq 1 ]]; then
    say "停止并禁用服务"
    for u in qingli-web.service qingli-watch.service qingli-scan.timer qingli-scan.service; do
        sysd_do stop "$u" >/dev/null 2>&1 || true
        sysd_do disable "$u" >/dev/null 2>&1 || true
    done
    say "移除单元文件"
    rm -f "$UNIT_DIR"/qingli-web.service "$UNIT_DIR"/qingli-watch.service \
          "$UNIT_DIR"/qingli-scan.service "$UNIT_DIR"/qingli-scan.timer
    have_systemd && systemctl daemon-reload || true
    say "移除二进制"
    rm -f "$BIN_DST" "$CTL_DST"
    if [[ $PURGE -eq 1 ]]; then
        say "删除配置与数据（--purge）"
        rm -rf "$ETC_DIR" "$LIB_DIR"
    else
        warn "已保留配置 $ETC_DIR 与数据 $LIB_DIR（加 --purge 可一并删除）"
    fi
    ok "卸载完成"
    exit 0
fi

# ---------------------------------------------------------------- 选扫描根
is_readonly_mount() {
    local opts
    opts=$(findmnt -no OPTIONS --target "$1" 2>/dev/null || true)
    [[ "$opts" == *",ro"* || "$opts" == "ro"* ]]
}
pick_largest_mount() {
    # df -PT 列：fs type blocks used avail capacity mount
    df -PT -x tmpfs -x devtmpfs -x squashfs -x overlay -x iso9660 -x ramfs 2>/dev/null |
    awk 'NR>1 && $2 ~ /^(ext[234]|xfs|btrfs|f2fs|zfs|vfat|nfs[0-9]?|cifs)$/ {print $5, $7}' |
    sort -rn |
    while read -r avail mnt; do
        [[ -w "$mnt" ]] || continue
        is_readonly_mount "$mnt" && continue
        echo "$mnt"
        break
    done
}

if [[ -n "$ROOT_OVERRIDE" ]]; then
    SCAN_ROOT=$ROOT_OVERRIDE
else
    SCAN_ROOT=$(pick_largest_mount || true)
    [[ -n "$SCAN_ROOT" ]] || die "无法自动判定扫描根，请显式指定 --root（如 --root /data）"
    say "自动选择扫描根：$SCAN_ROOT（容量最大的可写真实挂载点）"
fi
[[ -d "$SCAN_ROOT" ]] || die "扫描根不存在: $SCAN_ROOT"
SCAN_ROOT=$(realpath "$SCAN_ROOT")

# ---------------------------------------------------------------- 依赖与构建
if [[ -z "$BIN_SRC" && ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
    die "当前目录没有源码（缺少 CMakeLists.txt）。
       本仓库只包含安装脚本，请用 --bin 指定已编译好的二进制：
         sudo bash install.sh --root /data --bin /path/to/qingli"
fi

need_pkgs=()
command -v cmake >/dev/null || need_pkgs+=(cmake)
command -v ninja >/dev/null || command -v ninja-build >/dev/null || need_pkgs+=(ninja-build)
command -v g++ >/dev/null || need_pkgs+=(g++)
command -v pkg-config >/dev/null || need_pkgs+=(pkg-config)
pkg-config --exists sqlite3 2>/dev/null || need_pkgs+=(libsqlite3-dev)

if [[ -z "$BIN_SRC" ]]; then
    if [[ ${#need_pkgs[@]} -gt 0 ]]; then
        say "安装构建依赖：${need_pkgs[*]}"
        if command -v apt-get >/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || true
            apt-get install -y -qq "${need_pkgs[@]}" || die "依赖安装失败，请先手动安装：${need_pkgs[*]}"
        elif command -v dnf >/dev/null; then
            dnf install -y "${need_pkgs[*]}" || die "依赖安装失败"
        elif command -v yum >/dev/null; then
            yum install -y "${need_pkgs[@]}" || die "依赖安装失败"
        else
            die "不认识包管理器，请手动安装：${need_pkgs[*]}"
        fi
    fi
    say "编译（Release）"
    cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$SRC_DIR/build" -j"$(nproc)" >/dev/null
    BIN_SRC="$SRC_DIR/build/qingli"
fi
[[ -x "$BIN_SRC" ]] || die "找不到可执行文件: $BIN_SRC"
"$BIN_SRC" version >/dev/null || die "二进制无法运行: $BIN_SRC"

# ---------------------------------------------------------------- 目录与二进制
say "安装到 /usr/local/bin"
install -d -m 0755 "$(dirname "$BIN_DST")"
install -m 0755 "$BIN_SRC" "$BIN_DST"
install -m 0755 "$SRC_DIR/deploy/qingli-ctl" "$CTL_DST"
ok "$("$BIN_DST" version | head -1)"

install -d -m 0750 "$ETC_DIR" "$LIB_DIR"
ok "配置目录 $ETC_DIR / 数据目录 $LIB_DIR"

# ---------------------------------------------------------------- 端口与令牌
PORT=${PORT_OVERRIDE:-}
if [[ -z "$PORT" ]]; then
    if [[ -f "$CONF" && $FORCE -eq 0 ]]; then
        PORT=$(awk -F= '/^QL_PORT=/{print $2}' "$CONF")
    fi
fi
if [[ -z "$PORT" ]]; then
    PORT=8686
    for _ in $(seq 1 20); do
        if ! ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then break; fi
        PORT=$((PORT + 1))
    done
fi

TOKEN=""
if [[ -f "$WEB_ENV" && $FORCE -eq 0 ]]; then
    TOKEN=$(awk -F= '/^QL_WEB_TOKEN=/{print $2}' "$WEB_ENV")
fi
if [[ -z "$TOKEN" ]]; then
    TOKEN=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | cut -c1-32)
fi
umask 077
cat > "$WEB_ENV" <<EOF
# 由 qingli install.sh 生成（权限 0600）。改令牌后需 restart web 服务。
QL_WEB_TOKEN=$TOKEN
EOF
chmod 0600 "$WEB_ENV"
ok "访问令牌已写入 $WEB_ENV"

# ---------------------------------------------------------------- 渲染单元
say "写入 systemd 单元"
render() {
    local src=$1 dst=$2
    sed "s|{{ROOT}}|$SCAN_ROOT|g" "$src" > "$dst"
    chmod 0644 "$dst"
}
render "$SRC_DIR/deploy/qingli-scan.service"  "$UNIT_DIR/qingli-scan.service"
render "$SRC_DIR/deploy/qingli-scan.timer"    "$UNIT_DIR/qingli-scan.timer"
render "$SRC_DIR/deploy/qingli-web.service"   "$UNIT_DIR/qingli-web.service"
render "$SRC_DIR/deploy/qingli-watch.service" "$UNIT_DIR/qingli-watch.service"
ok "4 个单元已生成（扫描根 $SCAN_ROOT）"

# 端口写进 web 单元（默认 8686，可能因占用顺延）
sed -i "s|--port 8686|--port $PORT|" "$UNIT_DIR/qingli-web.service"

cat > "$CONF" <<EOF
# qingli-ctl 读取的安装信息（由 install.sh 生成）
QL_ROOT=$SCAN_ROOT
QL_PORT=$PORT
QL_BIN=$BIN_DST
QL_ETC=$ETC_DIR
QL_DB=$LIB_DIR/qingli.db
QL_TOKEN_FILE=$WEB_ENV
EOF
chmod 0644 "$CONF"

# ---------------------------------------------------------------- 启用服务
if have_systemd; then
    say "启用并启动服务"
    systemctl daemon-reload
    systemctl enable --now qingli-scan.timer >/dev/null 2>&1 || warn "启用定时器失败"
    systemctl enable --now qingli-web.service >/dev/null 2>&1 || warn "启动 Web 服务失败（详情：journalctl -u qingli-web -n 50）"
    ok "qingli-scan.timer / qingli-web.service 已启用"
else
    warn "本机没有运行 systemd：文件已安装，但需要你手动启动（或直接跑二进制）"
    warn "  手动跑 Web: $BIN_DST serve $SCAN_ROOT --db $LIB_DIR/qingli.db --port $PORT --token $TOKEN"
fi

# ---------------------------------------------------------------- 首次扫描
if [[ $FIRST_SCAN -eq 1 ]]; then
    if have_systemd; then
        say "触发首次全量扫描（后台进行，可用 qingli-ctl status 观察）"
        systemctl start --no-block qingli-scan.service 2>/dev/null || warn "首次扫描触发失败，可稍后执行 qingli-ctl scan-now"
    else
        say "执行首次全量扫描（可能需要一段时间）"
        "$BIN_DST" scan "$SCAN_ROOT" --out "$LIB_DIR/snapshot.spool" --engine auto >/dev/null && \
        "$BIN_DST" import "$LIB_DIR/snapshot.spool" --db "$LIB_DIR/qingli.db" >/dev/null && \
        ok "首扫完成" || warn "首扫失败，可稍后执行 qingli-ctl scan-now"
    fi
fi

# ---------------------------------------------------------------- 汇总
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

$(printf '%s' "$c_ok")安装完成$(printf '%s' "$c_off")

  扫描根      : $SCAN_ROOT
  数据目录    : $LIB_DIR
  配置文件    : $CONF
  访问令牌    : $TOKEN
  本机地址    : http://127.0.0.1:$PORT/?token=$TOKEN
$( [[ -n "$HOST_IP" ]] && echo "  局域网地址  : http://$HOST_IP:$PORT/?token=$TOKEN" )

常用命令：
  qingli-ctl status              # 三个服务的运行状态
  qingli-ctl info                # 安装信息 + 快照概况
  qingli-ctl restart web         # 重启界面（改完令牌/端口后用）
  qingli-ctl start watch         # 开启实时监听（需要 CAP_SYS_ADMIN）
  qingli-ctl scan-now            # 立即做一次全量扫描
  qingli-ctl logs web            # 看日志
  qingli-ctl update              # 升级到最新 Release（自动备份 + 重启）
  qingli-ctl stop all            # 全部停止
  sudo ./install.sh --uninstall  # 卸载（保留数据）

提示：远程访问请用 SSH 隧道，不要把 $PORT 端口直接暴露到公网：
  ssh -L $PORT:127.0.0.1:$PORT user@server
EOF
