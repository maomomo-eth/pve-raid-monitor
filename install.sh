#!/usr/bin/env bash

# PVE8 + LSI/MegaRAID 2208 一键安装器。
# 支持：
#   curl -fsSL https://raw.githubusercontent.com/maomomo-eth/pve-raid-monitor/main/install.sh | bash
#
# 安装器不会从不明来源下载 storcli；storcli 必须由用户/硬件厂商预先提供。

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

readonly REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/maomomo-eth/pve-raid-monitor}"
readonly REPOSITORY_REF="${REPOSITORY_REF:-main}"
readonly MONITOR_BIN="/usr/local/sbin/pve-raid-monitor"
readonly CONFIG_FILE="/etc/pve-raid-monitor.conf"
readonly SERVICE_FILE="/etc/systemd/system/pve-raid-monitor.service"
readonly TIMER_FILE="/etc/systemd/system/pve-raid-monitor.timer"
readonly LOG_DIR="/var/log/pve-raid-monitor"

NO_APT=0
SKIP_INITIAL_CHECK=0
SOURCE_DIR=""
WORK_DIR=""

info() {
    printf '[信息] %s\n' "$*"
}

warn() {
    printf '[警告] %s\n' "$*" >&2
}

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
PVE 阵列每日监控一键安装器

用法：
  install.sh [选项]

选项：
  --no-apt              不自动安装 smartmontools；缺少 smartctl 时直接失败
  --skip-initial-check  安装完成后不立即执行首次硬盘检查
  -h, --help            显示帮助

环境变量：
  REPOSITORY_REF        下载的 GitHub 分支或版本，默认 main
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        find "$WORK_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
        rmdir "$WORK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --no-apt)
                NO_APT=1
                ;;
            --skip-initial-check)
                SKIP_INITIAL_CHECK=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "未知选项：${arg}"
                ;;
        esac
    done
}

require_root() {
    if (( EUID != 0 )); then
        die "请使用 root 运行，例如：curl -fsSL <安装地址> | bash"
    fi
}

resolve_local_source() {
    local source_file="${BASH_SOURCE[0]:-}"
    local candidate_dir

    if [[ -z "$source_file" || "$source_file" == "/dev/stdin" || ! -f "$source_file" ]]; then
        return 1
    fi

    candidate_dir="$(cd -- "$(dirname -- "$source_file")" && pwd)"
    if [[ -f "$candidate_dir/pve-raid-monitor.sh" && \
        -f "$candidate_dir/pve-raid-monitor.service" && \
        -f "$candidate_dir/pve-raid-monitor.timer" ]]; then
        SOURCE_DIR="$candidate_dir"
        return 0
    fi
    return 1
}

download_source() {
    local archive_file
    local archive_url
    local extracted_dir

    command -v tar >/dev/null 2>&1 || die "系统缺少 tar，无法下载项目文件"
    WORK_DIR="$(mktemp -d /tmp/pve-raid-monitor-install.XXXXXX)"
    archive_file="$WORK_DIR/source.tar.gz"
    archive_url="${REPOSITORY_URL}/archive/refs/heads/${REPOSITORY_REF}.tar.gz"

    info "正在下载 ${REPOSITORY_URL}（${REPOSITORY_REF}）"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --retry 3 \
            --connect-timeout 15 --proto '=https' --tlsv1.2 \
            "$archive_url" --output "$archive_file" || die "下载项目失败"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --tries=3 --timeout=15 \
            --output-document="$archive_file" "$archive_url" || die "下载项目失败"
    else
        die "系统缺少 curl 或 wget，无法下载项目文件"
    fi

    tar -xzf "$archive_file" -C "$WORK_DIR" || die "解压项目失败"
    extracted_dir="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$extracted_dir" ]] || die "下载内容中没有找到项目目录"
    SOURCE_DIR="$extracted_dir"
}

install_smartmontools() {
    if command -v smartctl >/dev/null 2>&1; then
        info "已找到 smartctl：$(command -v smartctl)"
        return 0
    fi

    (( NO_APT == 0 )) || die "找不到 smartctl；请删除 --no-apt 后重试，或手动安装 smartmontools"
    command -v apt-get >/dev/null 2>&1 || die "找不到 apt-get，无法自动安装 smartmontools"

    info "未找到 smartctl，正在安装 smartmontools"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || die "apt-get update 失败"
    apt-get install -y smartmontools || die "安装 smartmontools 失败"
    command -v smartctl >/dev/null 2>&1 || die "smartmontools 安装后仍找不到 smartctl"
}

find_storcli() {
    local candidate
    local resolved

    for candidate in storcli64 storcli; do
        resolved="$(command -v "$candidate" 2>/dev/null || true)"
        if [[ -n "$resolved" && -x "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    for candidate in \
        /usr/local/sbin/storcli64 \
        /usr/local/sbin/storcli \
        /usr/sbin/storcli64 \
        /usr/sbin/storcli \
        /usr/bin/storcli64 \
        /usr/bin/storcli \
        /opt/MegaRAID/storcli/storcli64 \
        /opt/MegaRAID/storcli/storcli; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install_files() {
    [[ -f "$SOURCE_DIR/pve-raid-monitor.sh" ]] || die "项目文件不完整：缺少 pve-raid-monitor.sh"
    [[ -f "$SOURCE_DIR/pve-raid-monitor.service" ]] || die "项目文件不完整：缺少 systemd service"
    [[ -f "$SOURCE_DIR/pve-raid-monitor.timer" ]] || die "项目文件不完整：缺少 systemd timer"
    [[ -f "$SOURCE_DIR/pve-raid-monitor.conf.example" ]] || die "项目文件不完整：缺少配置模板"

    install -D -m 0750 "$SOURCE_DIR/pve-raid-monitor.sh" "$MONITOR_BIN"
    install -D -m 0644 "$SOURCE_DIR/pve-raid-monitor.service" "$SERVICE_FILE"
    install -D -m 0644 "$SOURCE_DIR/pve-raid-monitor.timer" "$TIMER_FILE"

    if [[ -e "$CONFIG_FILE" ]]; then
        info "保留已有配置：${CONFIG_FILE}"
    else
        install -D -m 0640 "$SOURCE_DIR/pve-raid-monitor.conf.example" "$CONFIG_FILE"
        info "已创建配置：${CONFIG_FILE}"
    fi
}

enable_timer() {
    command -v systemctl >/dev/null 2>&1 || die "系统缺少 systemctl，无法配置每日定时任务"
    systemctl daemon-reload
    systemctl enable --now pve-raid-monitor.timer || die "启用 pve-raid-monitor.timer 失败"
}

run_initial_check() {
    local check_rc

    if (( SKIP_INITIAL_CHECK == 1 )); then
        info "已跳过首次硬盘检查"
        return 0
    fi

    info "正在执行首次硬盘检查"
    if systemctl start pve-raid-monitor.service; then
        check_rc=0
    else
        check_rc=$?
    fi

    case "$check_rc" in
        0)
            info "首次检查正常"
            ;;
        1)
            warn "安装完成，但首次检查发现警告；请查看 journalctl 和本地报告"
            ;;
        2)
            warn "安装完成，但首次检查发现严重异常；请立即查看 CacheVault/阵列状态"
            ;;
        *)
            warn "安装完成，但首次检查服务返回退出码 ${check_rc}"
            ;;
    esac
}

main() {
    local storcli_path

    parse_args "$@"
    require_root

    if ! resolve_local_source; then
        download_source
    else
        info "使用本地项目文件：${SOURCE_DIR}"
    fi

    install_smartmontools
    if ! storcli_path="$(find_storcli)"; then
        die "找不到 storcli/storcli64。请先安装 LSI/Broadcom/浪潮官方 StorCLI，再重新运行安装器"
    fi
    info "已找到 StorCLI：${storcli_path}"

    install_files
    mkdir -p "$LOG_DIR"
    enable_timer
    run_initial_check

    printf '\n安装完成。\n'
    printf '程序：%s\n' "$MONITOR_BIN"
    printf '配置：%s\n' "$CONFIG_FILE"
    printf '日志：%s\n' "$LOG_DIR"
    printf '定时器：systemctl status pve-raid-monitor.timer\n'
    printf '最近日志：journalctl -u pve-raid-monitor.service -n 100 --no-pager\n'
}

main "$@"
