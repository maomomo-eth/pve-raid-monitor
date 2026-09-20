#!/usr/bin/env bash

# PVE8 + LSI/MegaRAID 2208 每日磁盘与阵列检查程序。
#
# 检查内容：
#   1. StorCLI 控制器、CacheVault/BBU、温度、虚拟盘和物理盘状态。
#   2. 物理盘数量、SAS/SATA 数量、RAID 类型和状态。
#   3. 物理盘媒体错误、其他错误、预测失败和 SMART 告警计数。
#   4. 可选的 smartctl MegaRAID 透传健康检查。
#
# 退出码：
#   0 = 正常
#   1 = 有警告
#   2 = 有严重问题或检查命令失败

set -Eeuo pipefail

# StorCLI 输出字段是英文，使用 C.UTF-8 保证解析稳定并兼容中文日志。
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${CONFIG_FILE:-/etc/pve-raid-monitor.conf}"

if [[ -r "$CONFIG_FILE" ]]; then
    # 配置文件由 root 管理，只放变量赋值，不要在其中执行外部命令。
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

: "${CONTROLLER_ID:=0}"
: "${EXPECTED_PD_COUNT:=8}"
: "${EXPECTED_SAS_COUNT:=4}"
: "${EXPECTED_SATA_COUNT:=4}"
: "${EXPECTED_VD_COUNT:=2}"
: "${EXPECTED_VD_TYPE:=RAID10}"
: "${SMART_BASE_DEVICE:=auto}"
: "${SMART_DRIVER:=auto}"
: "${SMART_DEVICE_IDS:=0 1 2 3 4 5 6 7}"
: "${REQUIRE_SMARTCTL:=0}"
: "${LOG_DIR:=/var/log/pve-raid-monitor}"
: "${REPORT_KEEP_DAYS:=90}"
: "${COMMAND_TIMEOUT:=120}"
: "${ROC_TEMP_WARN:=75}"
: "${ROC_TEMP_CRIT:=85}"
: "${CACHEVAULT_TEMP_WARN:=55}"
: "${CACHEVAULT_TEMP_CRIT:=65}"
: "${ALERT_EMAIL:=}"

ISSUES=()
WARNINGS=()
TMP_DIR=""
REPORT_FILE=""
HOST_NAME="$(hostname -s 2>/dev/null || hostname)"

add_issue() {
    ISSUES+=("$*")
}

add_warning() {
    WARNINGS+=("$*")
}

log_line() {
    local level="$1"
    shift
    local message="$*"
    printf '%s [%s] %s\n' "$(date '+%F %T %z')" "$level" "$message"
    if command -v logger >/dev/null 2>&1; then
        logger -t pve-raid-monitor -- "[$level] $message" || true
    fi
}

resolve_binary() {
    local configured="$1"
    shift
    local candidate
    local resolved

    if [[ -n "$configured" ]]; then
        if [[ "$configured" == */* ]]; then
            if [[ -x "$configured" ]]; then
                printf '%s\n' "$configured"
                return 0
            fi
            return 1
        fi
        resolved="$(command -v "$configured" 2>/dev/null || true)"
        if [[ -n "$resolved" && -x "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
        return 1
    fi

    for candidate in "$@"; do
        resolved="$(command -v "$candidate" 2>/dev/null || true)"
        if [[ -n "$resolved" && -x "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    # 某些厂商把 StorCLI 放在 PATH 之外，systemd 服务也需要能够找到它。
    for resolved in \
        /usr/local/sbin/storcli64 \
        /usr/local/sbin/storcli \
        /usr/sbin/storcli64 \
        /usr/sbin/storcli \
        /usr/bin/storcli64 \
        /usr/bin/storcli \
        /opt/MegaRAID/storcli/storcli64 \
        /opt/MegaRAID/storcli/storcli; do
        if [[ -x "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done
    return 1
}

trim_text() {
    local value="$*"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

get_equals_value() {
    local key="$1"
    local file="$2"
    awk -F= -v wanted="$key" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        {
            left = trim($1)
            if (left == wanted) {
                print trim($2)
                exit
            }
        }
    ' "$file"
}

get_number() {
    local value="$1"
    if [[ "$value" =~ ([0-9]+) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' ""
    fi
}

command_text() {
    local item
    local output=""
    for item in "$@"; do
        printf -v item '%q' "$item"
        output+="${item} "
    done
    printf '%s' "${output% }"
}

run_capture() {
    local output_file="$1"
    shift
    if [[ -n "${TIMEOUT_BIN:-}" ]]; then
        "$TIMEOUT_BIN" --signal=TERM "${COMMAND_TIMEOUT}s" "$@" >"$output_file" 2>&1
    else
        "$@" >"$output_file" 2>&1
    fi
}

write_section() {
    local title="$1"
    local command_line="$2"
    local output_file="$3"
    local return_code="$4"

    {
        printf '\n===== %s =====\n' "$title"
        printf '命令：%s\n' "$command_line"
        printf '退出码：%s\n\n' "$return_code"
        if [[ -f "$output_file" ]]; then
            sed -n '1,2000p' "$output_file"
        fi
    } >>"$REPORT_FILE"
}

check_temperature() {
    local label="$1"
    local value="$2"
    local warn_limit="$3"
    local critical_limit="$4"

    if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
        add_warning "无法读取${label}温度"
        return
    fi

    if (( value >= critical_limit )); then
        add_issue "${label}温度为 ${value}°C，达到严重阈值 ${critical_limit}°C"
    elif (( value >= warn_limit )); then
        add_warning "${label}温度为 ${value}°C，达到警告阈值 ${warn_limit}°C"
    fi
}

scan_numeric_metric() {
    local file="$1"
    local key="$2"
    local label="$3"
    local value

    while IFS=$'\t' read -r drive value; do
        [[ -z "$value" ]] && continue
        if [[ -n "$drive" ]]; then
            add_issue "${drive} 的 ${label}为 ${value}"
        else
            add_issue "${label}为 ${value}"
        fi
    done < <(
        awk -F= -v wanted="$key" '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            /^Drive \/c[0-9]+\/e[0-9]+\/s[0-9]+/ {
                drive = $0
                sub(/[[:space:]].*$/, "", drive)
            }
            {
                left = trim($1)
                right = trim($2)
                if (left == wanted && right ~ /^[1-9][0-9]*$/) {
                    print drive "\t" right
                }
            }
        ' "$file"
    )
}

scan_smart_alerts() {
    local file="$1"
    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        add_issue "${line} 报告 SMART 告警"
    done < <(
        awk -F= '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            /^Drive \/c[0-9]+\/e[0-9]+\/s[0-9]+/ {
                drive = $0
                sub(/[[:space:]].*$/, "", drive)
            }
            {
                left = trim($1)
                right = trim($2)
                if (left == "S.M.A.R.T alert flagged by drive" && tolower(right) == "yes") {
                    print drive
                }
            }
        ' "$file"
    )
}

parse_physical_drives() {
    local source_file="$1"
    local rows_file="$TMP_DIR/physical-drive-rows.txt"
    local smart_map_file="$TMP_DIR/smart-device-map.txt"
    local pd_count=0
    local sas_count=0
    local sata_count=0
    local slot state interface model

    awk '
        /^PD LIST[[:space:]]*:/ { in_section = 1; next }
        in_section && /^EID=Physical/ { exit }
        in_section && $1 ~ /^[0-9]+:[0-9]+$/ {
            print $1 "\t" $3 "\t" $7 "\t" $12
        }
    ' "$source_file" >"$rows_file"

    # 保存 DID 到 SAS/SATA 的映射，供 smartctl 选择正确的 MegaRAID 设备类型。
    awk '
        /^PD LIST[[:space:]]*:/ { in_section = 1; next }
        in_section && /^EID=Physical/ { exit }
        in_section && $1 ~ /^[0-9]+:[0-9]+$/ {
            print $2 "\t" $7 "\t" $1
        }
    ' "$source_file" >"$smart_map_file"

    while IFS=$'\t' read -r slot state interface model; do
        [[ -z "$slot" ]] && continue
        pd_count=$((pd_count + 1))

        case "$state" in
            Onln)
                ;;
            Rbld|Rebuild|Cpybck|Copyback)
                add_warning "物理盘 ${slot} 当前状态为 ${state}，正在进行后台操作"
                ;;
            *)
                add_issue "物理盘 ${slot} 状态异常：${state}"
                ;;
        esac

        case "$interface" in
            SAS)
                sas_count=$((sas_count + 1))
                ;;
            SATA)
                sata_count=$((sata_count + 1))
                ;;
            *)
                add_warning "物理盘 ${slot} 接口类型无法识别：${interface}"
                ;;
        esac
    done <"$rows_file"

    if (( pd_count != EXPECTED_PD_COUNT )); then
        add_issue "物理盘数量为 ${pd_count}，预期为 ${EXPECTED_PD_COUNT}"
    fi
    if (( sas_count != EXPECTED_SAS_COUNT )); then
        add_issue "SAS 物理盘数量为 ${sas_count}，预期为 ${EXPECTED_SAS_COUNT}"
    fi
    if (( sata_count != EXPECTED_SATA_COUNT )); then
        add_issue "SATA 物理盘数量为 ${sata_count}，预期为 ${EXPECTED_SATA_COUNT}"
    fi
}

get_smart_interface() {
    local device_id="$1"
    local smart_map_file="$TMP_DIR/smart-device-map.txt"

    [[ -s "$smart_map_file" ]] || return 0
    awk -F'\t' -v wanted="$device_id" '$1 == wanted { print $2; exit }' "$smart_map_file"
}

parse_virtual_drives() {
    local source_file="$1"
    local rows_file="$TMP_DIR/virtual-drive-rows.txt"
    local vd_count=0
    local vd_name vd_type vd_state

    awk '
        /^VD LIST[[:space:]]*:/ { in_section = 1; next }
        in_section && /^VD=Virtual/ { exit }
        in_section && $1 ~ /^[0-9]+\/[0-9]+$/ {
            print $1 "\t" $2 "\t" $3
        }
    ' "$source_file" >"$rows_file"

    while IFS=$'\t' read -r vd_name vd_type vd_state; do
        [[ -z "$vd_name" ]] && continue
        vd_count=$((vd_count + 1))

        if [[ "$vd_type" != "$EXPECTED_VD_TYPE" ]]; then
            add_issue "虚拟盘 ${vd_name} 类型为 ${vd_type}，预期为 ${EXPECTED_VD_TYPE}"
        fi
        if [[ "$vd_state" != "Optl" && "$vd_state" != "Optimal" ]]; then
            add_issue "虚拟盘 ${vd_name} 状态异常：${vd_state}"
        fi
    done <"$rows_file"

    if (( vd_count != EXPECTED_VD_COUNT )); then
        add_issue "虚拟盘数量为 ${vd_count}，预期为 ${EXPECTED_VD_COUNT}"
    fi
}

parse_enclosures() {
    local source_file="$1"
    local enclosure_id enclosure_state

    while IFS=$'\t' read -r enclosure_id enclosure_state; do
        [[ -z "$enclosure_id" ]] && continue
        if [[ "$enclosure_state" != "OK" ]]; then
            add_issue "磁盘背板/Enclosure ${enclosure_id} 状态异常：${enclosure_state}"
        fi
    done < <(
        awk '
            /^Enclosure LIST[[:space:]]*:/ { in_section = 1; next }
            in_section && /^EID=Enclosure/ { exit }
            in_section && $1 ~ /^[0-9]+$/ { print $1 "\t" $2 }
        ' "$source_file"
    )
}

find_smart_base_device() {
    local candidate
    local probe_file="$TMP_DIR/smart-probe.txt"

    if [[ "$SMART_BASE_DEVICE" != "auto" ]]; then
        printf '%s\n' "$SMART_BASE_DEVICE"
        return 0
    fi

    shopt -s nullglob
    for candidate in /dev/sd?; do
        [[ -b "$candidate" ]] || continue
        # 某些 smartctl 版本即使成功读到识别信息也可能返回非零状态，
        # 因此这里以输出内容为准，不只判断命令退出码。
        if run_capture "$probe_file" "$SMARTCTL_BIN" -i -d "megaraid,0" "$candidate"; then
            :
        fi
        if grep -Eiq 'Device Model|Product|Serial Number|Vendor' "$probe_file"; then
            printf '%s\n' "$candidate"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

smart_output_is_healthy() {
    local file="$1"
    grep -Eiq \
        'SMART (overall-health self-assessment test result|Health Status)[[:space:]]*:[[:space:]]*(PASSED|OK)|overall-health.*PASSED' \
        "$file"
}

smart_output_is_failed() {
    local file="$1"
    grep -Eiq \
        'SMART (overall-health self-assessment test result|Health Status)[[:space:]]*:[[:space:]]*(FAILED|BAD)|overall-health.*FAILED' \
        "$file"
}

scan_smart_attributes() {
    local file="$1"
    local device_id="$2"
    local driver_item="$3"
    local line

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ [Cc]urrent_[Pp]ending|[Oo]ffline_[Uu]ncorrectable|[Rr]eported_[Uu]ncorrect|[Uu]ncorrectable_[Ss]ector|[Ee]nd-to-[Ee]nd ]]; then
            add_issue "smartctl 物理盘 ${device_id} (${driver_item}) 发现严重介质错误：$(trim_text "$line")"
        else
            add_warning "smartctl 物理盘 ${device_id} (${driver_item}) 发现介质退化指标：$(trim_text "$line")"
        fi
    done < <(
        awk '
            {
                lower = tolower($0)
                if (lower ~ /reallocated_sector_ct|reallocated_event_count|current_pending_sector|offline_uncorrectable|reported_uncorrect|uncorrectable_sector_ct|end-to-end_error/ && $NF ~ /^[1-9][0-9]*$/) {
                    print
                }
                if (lower ~ /^elements in grown defect list:[[:space:]]*[1-9][0-9]*/) {
                    print
                }
            }
        ' "$file"
    )
}

run_smart_checks() {
    local base_device="$1"
    local device_id interface output_file rc driver_list driver_item found
    local smart_summary="$TMP_DIR/smart-summary.txt"

    : >"$smart_summary"
    for device_id in $SMART_DEVICE_IDS; do
        interface="$(get_smart_interface "$device_id")"
        if [[ "$SMART_DRIVER" != "auto" ]]; then
            driver_list=("$SMART_DRIVER")
        else
            case "$interface" in
                SAS)
                    # SAS 盘不使用 SAT 透传，否则会出现 Read Device Identity failed。
                    driver_list=("megaraid")
                    ;;
                SATA)
                    # SATA 盘优先使用 SAT 透传；部分固件不支持时再回退。
                    driver_list=("sat+megaraid" "megaraid")
                    ;;
                *)
                    # 无法从 StorCLI 判断接口时保留兼容性回退顺序。
                    driver_list=("sat+megaraid" "megaraid")
                    ;;
            esac
        fi

        found=0
        for driver_item in "${driver_list[@]}"; do
            output_file="$TMP_DIR/smart-${device_id}-${driver_item//+/_}.txt"
            if run_capture "$output_file" "$SMARTCTL_BIN" -a -d "${driver_item},${device_id}" "$base_device"; then
                rc=0
            else
                rc=$?
            fi

            write_section \
                "smartctl 物理盘 ${device_id} (${interface:-未知接口}, ${driver_item})" \
                "$(command_text "$SMARTCTL_BIN" -a -d "${driver_item},${device_id}" "$base_device")" \
                "$output_file" \
                "$rc"

            if smart_output_is_healthy "$output_file"; then
                scan_smart_attributes "$output_file" "$device_id" "$driver_item"
                printf '物理盘 %s（%s，%s）：SMART 健康\n' \
                    "$device_id" "${interface:-未知接口}" "$driver_item" >>"$smart_summary"
                found=1
                break
            fi

            if smart_output_is_failed "$output_file"; then
                scan_smart_attributes "$output_file" "$device_id" "$driver_item"
                add_issue "物理盘 ${device_id}（${interface:-未知接口}）的 SMART 健康检查失败（${driver_item}）"
                found=1
                break
            fi
        done

        if (( found == 0 )); then
            add_warning "物理盘 ${device_id}（${interface:-未知接口}）无法通过 smartctl 读取健康状态，请检查 SMART 透传参数"
        fi
    done

    if [[ -s "$smart_summary" ]]; then
        cat "$smart_summary" >>"$REPORT_FILE"
    fi
}

send_email_alert() {
    local level="$1"
    local body

    [[ -n "$ALERT_EMAIL" ]] || return 0
    if ! command -v mail >/dev/null 2>&1; then
        add_warning "已配置 ALERT_EMAIL，但系统没有 mail 命令，无法发送邮件"
        return 0
    fi

    body="PVE 硬盘/阵列检查结果：${level}\n主机：${HOST_NAME}\n报告：${REPORT_FILE}\n"
    if ((${#ISSUES[@]} > 0)); then
        body+="\n严重问题：\n"
        body+="$(printf -- '- %s\n' "${ISSUES[@]}")"
    fi
    if ((${#WARNINGS[@]} > 0)); then
        body+="\n警告：\n"
        body+="$(printf -- '- %s\n' "${WARNINGS[@]}")"
    fi

    printf '%b\n' "$body" | mail -s "[PVE][${level}] ${HOST_NAME} 阵列检查" "$ALERT_EMAIL" || \
        add_warning "发送告警邮件失败"
}

main() {
    local storcli_show_file="$TMP_DIR/storcli-controller-show-all.txt"
    local storcli_pd_file="$TMP_DIR/storcli-physical-show-all.txt"
    local storcli_vd_file="$TMP_DIR/storcli-virtual-show-all.txt"
    local storcli_event_file="$TMP_DIR/storcli-events.txt"
    local rc controller_status roc_temp cachevault_line cachevault_temp
    local smart_base_device
    local storcli_command

    if (( EUID != 0 )); then
        printf '错误：必须以 root 身份运行。\n' >&2
        exit 2
    fi

    mkdir -p "$LOG_DIR"
    REPORT_FILE="$LOG_DIR/report-$(date '+%Y%m%d-%H%M%S').log"
    {
        printf 'PVE 硬盘与阵列每日检查报告\n'
        printf '主机：%s\n' "$HOST_NAME"
        printf '时间：%s\n' "$(date '+%F %T %z')"
        printf '控制器：/c%s\n' "$CONTROLLER_ID"
        printf '预期拓扑：%s 个物理盘（SAS=%s，SATA=%s），%s 个 %s 虚拟盘\n' \
            "$EXPECTED_PD_COUNT" "$EXPECTED_SAS_COUNT" "$EXPECTED_SATA_COUNT" "$EXPECTED_VD_COUNT" "$EXPECTED_VD_TYPE"
    } >"$REPORT_FILE"

    if ! STORCLI_BIN="$(resolve_binary "${STORCLI_BIN:-}" storcli64 storcli)"; then
        add_issue "找不到 storcli/storcli64，无法检查 RAID 控制器"
    else
        storcli_command="$(command_text "$STORCLI_BIN" "/c${CONTROLLER_ID}" show all)"
        if run_capture "$storcli_show_file" "$STORCLI_BIN" "/c${CONTROLLER_ID}" show all; then
            rc=0
        else
            rc=$?
            add_issue "StorCLI 控制器检查命令失败，退出码 ${rc}"
        fi
        write_section "StorCLI 控制器总览" "$storcli_command" "$storcli_show_file" "$rc"

        storcli_command="$(command_text "$STORCLI_BIN" "/c${CONTROLLER_ID}/eall/sall" show all)"
        if run_capture "$storcli_pd_file" "$STORCLI_BIN" "/c${CONTROLLER_ID}/eall/sall" show all; then
            rc=0
        else
            rc=$?
            add_issue "StorCLI 物理盘检查命令失败，退出码 ${rc}"
        fi
        write_section "StorCLI 物理盘详细信息" "$storcli_command" "$storcli_pd_file" "$rc"

        storcli_command="$(command_text "$STORCLI_BIN" "/c${CONTROLLER_ID}/vall" show all)"
        if run_capture "$storcli_vd_file" "$STORCLI_BIN" "/c${CONTROLLER_ID}/vall" show all; then
            rc=0
        else
            rc=$?
            add_issue "StorCLI 虚拟盘检查命令失败，退出码 ${rc}"
        fi
        write_section "StorCLI 虚拟盘详细信息" "$storcli_command" "$storcli_vd_file" "$rc"

        storcli_command="$(command_text "$STORCLI_BIN" "/c${CONTROLLER_ID}" show events)"
        if run_capture "$storcli_event_file" "$STORCLI_BIN" "/c${CONTROLLER_ID}" show events; then
            rc=0
        else
            rc=$?
            add_warning "StorCLI 事件日志读取失败，退出码 ${rc}"
        fi
        write_section "StorCLI 控制器事件日志" "$storcli_command" "$storcli_event_file" "$rc"

        if [[ -s "$storcli_show_file" ]]; then
            controller_status="$(get_equals_value 'Controller Status' "$storcli_show_file")"
            if [[ -z "$controller_status" ]]; then
                add_issue "无法读取 Controller Status"
            elif [[ "$controller_status" != "Optimal" && "$controller_status" != "OK" ]]; then
                add_issue "控制器状态异常：${controller_status}"
            fi

            roc_temp="$(get_number "$(get_equals_value 'ROC temperature(Degree Celsius)' "$storcli_show_file")")"
            check_temperature "ROC" "$roc_temp" "$ROC_TEMP_WARN" "$ROC_TEMP_CRIT"

            cachevault_line="$(awk '
                /^Cachevault_Info[[:space:]]*:/ { in_section = 1; next }
                in_section && /^[[:space:]]*CVPM/ { print; exit }
                in_section && /^[A-Za-z].*:/ { exit }
            ' "$storcli_show_file")"
            if [[ -z "$cachevault_line" ]]; then
                add_warning "无法读取 CacheVault 状态"
            else
                if [[ "$cachevault_line" =~ (Dgd|Failed|Missing|Needs[[:space:]]Attention|Degraded) ]]; then
                    add_issue "CacheVault 状态异常：$(trim_text "$cachevault_line")"
                fi
                # 第一组数字通常是 CVPM 型号中的数字，不取它；取带 C 后缀的温度。
                cachevault_temp="$(printf '%s\n' "$cachevault_line" | sed -n 's/.*\([0-9][0-9]*\)C.*/\1/p')"
                check_temperature "CacheVault" "$cachevault_temp" "$CACHEVAULT_TEMP_WARN" "$CACHEVAULT_TEMP_CRIT"
            fi

            if [[ "$(get_equals_value 'Any Offline VD Cache Preserved' "$storcli_show_file")" == "Yes" ]]; then
                add_issue "控制器存在未释放的 Offline VD Cache"
            fi
            if [[ "$(get_equals_value 'Controller shutdown required' "$storcli_show_file")" == "Yes" ]]; then
                add_issue "控制器要求关机/重启完成操作"
            fi
            if [[ "$(get_equals_value 'Memory Uncorrectable Errors' "$storcli_show_file")" =~ ^[1-9][0-9]*$ ]]; then
                add_issue "控制器 Memory Uncorrectable Errors 非零"
            fi
            if [[ "$(get_equals_value 'Memory Correctable Errors' "$storcli_show_file")" =~ ^[1-9][0-9]*$ ]]; then
                add_warning "控制器 Memory Correctable Errors 非零"
            fi

            parse_physical_drives "$storcli_show_file"
            parse_virtual_drives "$storcli_show_file"
            parse_enclosures "$storcli_show_file"
        fi

        if [[ -s "$storcli_pd_file" ]]; then
            scan_numeric_metric "$storcli_pd_file" "Media Error Count" "媒体错误计数"
            scan_numeric_metric "$storcli_pd_file" "Other Error Count" "其他错误计数"
            scan_numeric_metric "$storcli_pd_file" "Predictive Failure Count" "预测失败计数"
            scan_smart_alerts "$storcli_pd_file"
        fi

    fi

    if ! SMARTCTL_BIN="$(resolve_binary "${SMARTCTL_BIN:-}" smartctl)"; then
        if (( REQUIRE_SMARTCTL == 1 )); then
            add_issue "找不到 smartctl，且 REQUIRE_SMARTCTL=1"
        else
            add_warning "找不到 smartctl，已跳过 SMART 透传检查"
        fi
    elif [[ "$SMART_BASE_DEVICE" == "disabled" ]]; then
        add_warning "SMART 透传检查已通过 SMART_BASE_DEVICE=disabled 跳过"
    elif ! smart_base_device="$(find_smart_base_device)"; then
        if (( REQUIRE_SMARTCTL == 1 )); then
            add_issue "无法找到可用于 MegaRAID SMART 透传的基盘设备"
        else
            add_warning "无法找到可用于 MegaRAID SMART 透传的基盘设备，已跳过 smartctl"
        fi
    else
        printf '\n===== smartctl 配置 =====\n基盘设备：%s\n驱动模式：%s\n物理盘编号：%s\n' \
            "$smart_base_device" "$SMART_DRIVER" "$SMART_DEVICE_IDS" >>"$REPORT_FILE"
        run_smart_checks "$smart_base_device"
    fi

    find "$LOG_DIR" -type f -name 'report-*.log' -mtime "+${REPORT_KEEP_DAYS}" -delete 2>/dev/null || true

    local level="正常"
    if ((${#ISSUES[@]} > 0)); then
        level="严重异常"
    elif ((${#WARNINGS[@]} > 0)); then
        level="警告"
    fi

    {
        printf '\n===== 检查结论 =====\n'
        printf '结论：%s\n' "$level"
        if ((${#ISSUES[@]} > 0)); then
            printf '\n严重问题：\n'
            printf -- '- %s\n' "${ISSUES[@]}"
        fi
        if ((${#WARNINGS[@]} > 0)); then
            printf '\n警告：\n'
            printf -- '- %s\n' "${WARNINGS[@]}"
        fi
    } >>"$REPORT_FILE"

    if ((${#ISSUES[@]} > 0)); then
        log_line "CRITICAL" "${HOST_NAME} 阵列检查发现 ${#ISSUES[@]} 个严重问题，报告：${REPORT_FILE}"
        send_email_alert "严重异常"
        return 2
    fi
    if ((${#WARNINGS[@]} > 0)); then
        log_line "WARNING" "${HOST_NAME} 阵列检查有 ${#WARNINGS[@]} 个警告，报告：${REPORT_FILE}"
        send_email_alert "警告"
        return 1
    fi

    log_line "OK" "${HOST_NAME} 阵列检查正常，报告：${REPORT_FILE}"
    return 0
}

if ! TMP_DIR="$(mktemp -d /tmp/pve-raid-monitor.XXXXXX)"; then
    printf '错误：无法创建临时目录。\n' >&2
    exit 2
fi
trap 'rm -rf "$TMP_DIR"' EXIT

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"

if main "$@"; then
    exit 0
else
    rc=$?
    exit "$rc"
fi
