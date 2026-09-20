#!/usr/bin/env bash

# 使用模拟命令验证安装结果提示，不安装文件、不访问真实 systemd 或硬盘。
set -Eeuo pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "$project_dir/install.sh"

systemctl() {
    case "$1" in
        start) return "$mock_start_rc" ;;
        show)
            printf '%s\n' "$mock_properties"
            return "$mock_show_rc"
            ;;
        *) return 99 ;;
    esac
}

journalctl() {
    printf '%s\n' '模拟服务日志：控制器状态异常'
    return "$mock_journal_rc"
}

assert_contains() {
    if [[ "$output" != *"$1"* ]]; then
        printf '失败：%s，输出缺少：%s\n%s\n' "$case_name" "$1" "$output" >&2
        exit 1
    fi
}

run_case() {
    local case_name="$1" expected="$2"
    local mock_start_rc="$3" mock_properties="$4"
    local mock_show_rc="${5:-0}" mock_journal_rc="${6:-0}"
    local output
    # 独立子 shell 仍启用 errexit，避免测试掩盖诊断命令失败导致的提前退出。
    output="$(set -e; run_initial_check)"
    assert_contains "$expected"
    if (( mock_start_rc != 0 )); then
        assert_contains '模拟服务日志：控制器状态异常'
    fi
    printf '通过：%s\n' "$case_name"
}

# 警告输出也纳入断言。
warn() { printf '[警告] %s\n' "$*"; }

run_case '正常' '首次检查正常' 0 ''
run_case '警告' '首次检查发现警告' 1 $'Result=exit-code\nExecMainCode=1\nExecMainStatus=1'
run_case '严重异常不能被 systemctl 的退出码 1 降级' '首次检查发现严重异常或检查命令失败' 1 $'ExecMainStatus=2\nResult=exit-code\nExecMainCode=1'
run_case '信号 2 不是严重健康告警' '服务未正常完成' 1 $'Result=signal\nExecMainCode=2\nExecMainStatus=2'
run_case '超时不能按进程退出码解释' '服务未正常完成' 1 $'Result=timeout\nExecMainCode=1\nExecMainStatus=1'
run_case '进程未启动' '服务未正常完成' 1 $'Result=resources\nExecMainCode=0\nExecMainStatus=0'
run_case '执行文件错误' '服务未正常完成' 1 $'Result=exit-code\nExecMainCode=1\nExecMainStatus=203'
run_case '状态查询失败后仍展示日志' '无法读取首次检查服务状态' 1 '' 1
run_case '日志查询失败不撤销安装' '无法读取服务日志' 1 $'Result=exit-code\nExecMainCode=1\nExecMainStatus=2' 0 1
SKIP_INITIAL_CHECK=1
run_case '跳过首次检查' '已跳过首次硬盘检查' 0 ''

# 覆盖一键安装所用的 stdin 入口，确保导入保护没有跳过 main。
output="$(bash -s -- --help <"$project_dir/install.sh")"
case_name='stdin 入口'
assert_contains 'PVE 阵列每日监控一键安装器'
printf '通过：%s\n' "$case_name"

# 替换安装命令，仅验证新邮件组件会被纳入安装，不写入系统目录。
install() { printf '模拟安装：%s\n' "$*"; }
SOURCE_DIR="$project_dir"
output="$(install_files)"
case_name='安装邮件组件'
assert_contains "$project_dir/mail_report.py /usr/local/lib/pve-raid-monitor/mail_report.py"
printf '通过：%s\n' "$case_name"
