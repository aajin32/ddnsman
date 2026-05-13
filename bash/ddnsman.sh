#!/usr/bin/env bash
# ddnsman.sh — 阿里云 DNS 交互式管理 + DDNS 自动更新 (Bash 版)

CONFIG_FILE="$HOME/.alidns_config.sh"
CACHE_FILE="$HOME/.alidns_ip_cache.txt"
IP_SOURCES=("https://ipinfo.io/ip" "https://ifconfig.me" "https://icanhazip.com" "https://checkip.amazonaws.com")
DEFAULT_TTL=600
RECORD_TYPES=("A" "AAAA" "CNAME" "MX" "TXT" "NS")
DOMAIN=""
ACCESS_KEY_ID=""
ACCESS_KEY_SECRET=""
TTL=$DEFAULT_TTL
DDNS_RECORDS=""
DDNS_INTERVAL=5
IP_TIMEOUT=10

# ============================================================
#  工具函数
# ============================================================

get_script_path() {
    readlink -f "$0"
}

get_public_ip() {
    for src in "${IP_SOURCES[@]}"; do
        local ip
        ip=$(curl -s --max-time "$IP_TIMEOUT" "$src" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# ============================================================
#  阿里云 CLI 封装
# ============================================================

aliyun_cmd() {
    ALIBABA_CLOUD_ACCESS_KEY_ID="$ACCESS_KEY_ID" \
    ALIBABA_CLOUD_ACCESS_KEY_SECRET="$ACCESS_KEY_SECRET" \
    ALIBABA_CLOUD_REGION_ID="cn-hangzhou" \
    aliyun alidns "$@"
}

verify_config() {
    local result
    result=$(aliyun_cmd DescribeDomainRecords --DomainName "$DOMAIN" --PageSize 1 2>&1)
    echo "$result" | jq -e '.DomainRecords' >/dev/null 2>&1
}

# ============================================================
#  配置管理
# ============================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        [ -n "$ACCESS_KEY_ID" ] && [ -n "$ACCESS_KEY_SECRET" ] && [ -n "$DOMAIN" ]
        return $?
    fi
    return 1
}

save_config() {
    cat > "$CONFIG_FILE" <<EOF
ACCESS_KEY_ID="$ACCESS_KEY_ID"
ACCESS_KEY_SECRET="$ACCESS_KEY_SECRET"
DOMAIN="$DOMAIN"
TTL=$TTL
DDNS_RECORDS="$DDNS_RECORDS"
DDNS_INTERVAL=$DDNS_INTERVAL
EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ 配置已保存"
}

guide_config() {
    echo
    echo "请配置阿里云 AccessKey（RAM 子账号，最小权限）"
    echo
    read -p "AccessKey ID: " ACCESS_KEY_ID
    [ -z "$ACCESS_KEY_ID" ] && return 1
    read -sp "AccessKey Secret: " ACCESS_KEY_SECRET
    echo
    [ -z "$ACCESS_KEY_SECRET" ] && return 1
    read -p "默认域名（如 example.com）: " DOMAIN
    [ -z "$DOMAIN" ] && return 1
    TTL=$DEFAULT_TTL
    DDNS_RECORDS=""
    DDNS_INTERVAL=5
    echo "正在验证配置..."
    if verify_config; then
        save_config
        echo "✅ 配置验证通过"
        return 0
    else
        echo "❌ 配置验证失败，请检查 AccessKey 和域名"
        return 1
    fi
}

# ============================================================
#  缓存管理
# ============================================================

load_ip_cache() {
    if [ -f "$CACHE_FILE" ]; then
        cat "$CACHE_FILE"
    fi
}

save_ip_cache() {
    local rr="$1" ip="$2"
    local tmp
    tmp=$(grep -v "^$rr=" "$CACHE_FILE" 2>/dev/null || true)
    printf "%s\n%s=%s\n" "$tmp" "$rr" "$ip" > "$CACHE_FILE"
}

get_ddns_status() {
    local rr="$1"
    [[ ",$DDNS_RECORDS," == *",$rr,"* ]]
}

set_ddns_record() {
    local rr="$1" enabled="$2"
    local new=""
    if [ "$enabled" = "1" ]; then
        if ! get_ddns_status "$rr"; then
            DDNS_RECORDS="${DDNS_RECORDS:+$DDNS_RECORDS,}$rr"
        fi
    else
        IFS=',' read -ra arr <<< "$DDNS_RECORDS"
        for r in "${arr[@]}"; do
            [ "$r" != "$rr" ] && new="${new:+$new,}$r"
        done
        DDNS_RECORDS="$new"
    fi
    save_config
}

# ============================================================
#  DNS 操作
# ============================================================

get_records() {
    aliyun_cmd DescribeDomainRecords --DomainName "$DOMAIN" --PageSize 500 2>/dev/null
}

add_dns_record() {
    local rr="$1" rtype="$2" value="$3" ttl="${4:-$DEFAULT_TTL}" priority="$5"
    local add_cmd=(--DomainName "$DOMAIN" --RR "$rr" --Type "$rtype" --Value "$value" --TTL "$ttl")
    [ -n "$priority" ] && add_cmd+=(--Priority "$priority")
    aliyun_cmd AddDomainRecord "${add_cmd[@]}" 2>/dev/null
}

update_dns_record() {
    local rid="$1" rr="$2" rtype="$3" value="$4" ttl="${5:-$DEFAULT_TTL}" priority="$6"
    local cmd=(--RecordId "$rid" --RR "$rr" --Type "$rtype" --Value "$value" --TTL "$ttl")
    [ -n "$priority" ] && cmd+=(--Priority "$priority")
    aliyun_cmd UpdateDomainRecord "${cmd[@]}" 2>/dev/null
}

delete_dns_record() {
    local rid="$1"
    aliyun_cmd DeleteDomainRecord --RecordId "$rid" 2>/dev/null
}

# ============================================================
#  Cron 管理
# ============================================================

install_cron() {
    local interval="${1:-$DDNS_INTERVAL}"
    local script
    script=$(get_script_path)
    local cron_line="*/$interval * * * * $BASH $script --watch >> $HOME/.ddnsman.log 2>&1"
    local tmp
    tmp=$(crontab -l 2>/dev/null || true)
    local found=0
    local new=""
    while IFS= read -r line; do
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
        if echo "$stripped" | grep -qF "$script" && echo "$stripped" | grep -qF -- "--watch"; then
            found=1
            if echo "$stripped" | grep -q '^#'; then
                new="$new"$'\n'"$cron_line"
            elif [ "$stripped" != "$(echo "$cron_line" | sed 's/^[[:space:]]*//')" ]; then
                new="$new"$'\n'"$cron_line"
            else
                new="$new"$'\n'"$line"
            fi
        else
            new="$new"$'\n'"$line"
        fi
    done <<< "$tmp"
    [ "$found" -eq 0 ] && new="$new"$'\n'"$cron_line"
    new=$(echo "$new" | sed '/^$/d')
    echo "$new" | crontab -
}

uninstall_cron() {
    local script
    script=$(get_script_path)
    local tmp
    tmp=$(crontab -l 2>/dev/null || true)
    local found=0
    local new=""
    while IFS= read -r line; do
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
        if echo "$stripped" | grep -qF "$script" && echo "$stripped" | grep -qF -- "--watch" && ! echo "$stripped" | grep -q '^#'; then
            new="$new"$'\n'"# $line"
            found=1
        else
            new="$new"$'\n'"$line"
        fi
    done <<< "$tmp"
    new=$(echo "$new" | sed '/^$/d')
    [ "$found" -eq 1 ] && echo "$new" | crontab -
    return $found
}

is_cron_installed() {
    local script
    script=$(get_script_path)
    local cron_output
    cron_output=$(crontab -l 2>/dev/null || true)
    while IFS= read -r line; do
        local stripped
        stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
        if echo "$stripped" | grep -qF "$script" && echo "$stripped" | grep -qF -- "--watch" && ! echo "$stripped" | grep -q '^#'; then
            return 0
        fi
    done <<< "$cron_output"
    return 1
}

# ============================================================
#  交互流程：新增记录
# ============================================================

add_record_flow() {
    local rr rtype ip use_auto use_ddns priority confirm summary
    read -p "主机记录（如 www、@）: " rr
    [ -z "$rr" ] && return

    echo "记录类型:"
    PS3="请选择 (1-${#RECORD_TYPES[@]}): "
    select rtype in "${RECORD_TYPES[@]}"; do
        [ -n "$rtype" ] && break
    done

    priority=""
    if [ "$rtype" = "MX" ]; then
        read -p "MX 优先级（默认 10）: " priority
        priority="${priority:-10}"
    fi

    read -p "是否自动获取本机公网 IP？(y/N): " use_auto
    if [ "$use_auto" = "y" ] || [ "$use_auto" = "Y" ]; then
        echo -n "⏳ 正在获取公网 IP..."
        ip=$(get_public_ip)
        if [ -n "$ip" ]; then
            echo " ✅ $ip"
        else
            echo " ❌ 获取失败，改为手动输入"
            read -p "记录值: " ip
        fi
    else
        read -p "记录值: " ip
    fi
    [ -z "$ip" ] && return

    read -p "是否开启定时更新（检测 IP 变化自动同步）？(y/N): " use_ddns

    summary="$rr.$DOMAIN  $rtype -> $ip"
    [ -n "$priority" ] && summary="$summary (优先级 $priority)"
    summary="$summary  TTL=$TTL"
    [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ] && summary="$summary  [定时更新]"

    read -p "确认新增: $summary (y/N): " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "已取消"; return; }

    if add_dns_record "$rr" "$rtype" "$ip" "$TTL" "$priority"; then
        echo "✅ 已新增: $summary"
    else
        echo "❌ 新增失败"
        return
    fi

    if [ "$use_ddns" = "y" ] || [ "$use_ddns" = "Y" ]; then
        set_ddns_record "$rr" 1
        if ! is_cron_installed; then
            install_cron "$DDNS_INTERVAL"
            echo "📌 已添加 crontab 定时任务，每 $DDNS_INTERVAL 分钟检测一次"
        fi
        echo "📌 已加入定时更新列表"
    fi
}

# ============================================================
#  交互流程：单条记录操作
# ============================================================

record_menu_flow() {
    local rid="$1" rr="$2" dm="$3" rtype="$4" val="$5" priority="$6"
    local ddns_label="关闭"
    get_ddns_status "$rr" && ddns_label="开启"

    echo "操作 [$rr.$dm ($rtype -> $val)]"
    PS3="请选择 (1-4): "
    select action in "修改记录值" "删除该记录" "定时更新 [$ddns_label]" "返回"; do
        case $action in
            "修改记录值")
                read -p "新的记录值 (当前: $val): " new_val
                new_val="${new_val:-$val}"
                if update_dns_record "$rid" "$rr" "$rtype" "$new_val" "$TTL" "$priority"; then
                    echo "✅ 已更新: $rr.$dm -> $new_val"
                else
                    echo "❌ 更新失败"
                fi
                break;;

            "删除该记录")
                read -p "确认删除 $rr.$dm？此操作不可恢复 (y/N): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    if delete_dns_record "$rid"; then
                        echo "✅ 已删除"
                    else
                        echo "❌ 删除失败"
                    fi
                fi
                break;;

            "定时更新 [$ddns_label]")
                if get_ddns_status "$rr"; then
                    set_ddns_record "$rr" 0
                    ddns_label="关闭"
                    echo "📌 $rr 已从定时更新列表移除"
                    [ -z "$DDNS_RECORDS" ] && uninstall_cron && echo "📌 已暂停 crontab 定时任务"
                else
                    set_ddns_record "$rr" 1
                    ddns_label="开启"
                    echo "📌 $rr 已加入定时更新列表"
                    if ! is_cron_installed; then
                        install_cron "$DDNS_INTERVAL"
                        echo "📌 已添加 crontab 定时任务，每 $DDNS_INTERVAL 分钟检测一次"
                    fi
                fi
                break;;

            "返回") break;;
        esac
    done
}

# ============================================================
#  交互流程：查看/管理记录
# ============================================================

list_records_flow() {
    local data records_json count i
    data=$(get_records) || { echo "❌ 获取解析记录失败"; return; }
    records_json=$(echo "$data" | jq '.DomainRecords.Record' 2>/dev/null)
    count=$(echo "$records_json" | jq 'length' 2>/dev/null || echo 0)

    [ "$count" -eq 0 ] && { echo "该域名下暂无解析记录"; return; }

    echo "----- 选择一条记录 -----"
    for ((i=0; i<count; i++)); do
        local rr dm rtype val mark=""
        rr=$(echo "$records_json" | jq -r ".[$i].RR")
        dm=$(echo "$records_json" | jq -r ".[$i].DomainName")
        rtype=$(echo "$records_json" | jq -r ".[$i].Type")
        val=$(echo "$records_json" | jq -r ".[$i].Value")
        get_ddns_status "$rr" && mark=" 🔄"
        printf "%2d. %s.%s  (%s -> %s)%s\n" $((i+1)) "$rr" "$dm" "$rtype" "$val" "$mark"
    done

    read -p "请输入序号: " idx
    idx=$((idx - 1))
    [ "$idx" -lt 0 ] || [ "$idx" -ge "$count" ] && { echo "序号无效"; return; }

    local rid rr dm rtype val priority
    rid=$(echo "$records_json" | jq -r ".[$idx].RecordId")
    rr=$(echo "$records_json" | jq -r ".[$idx].RR")
    dm=$(echo "$records_json" | jq -r ".[$idx].DomainName")
    rtype=$(echo "$records_json" | jq -r ".[$idx].Type")
    val=$(echo "$records_json" | jq -r ".[$idx].Value")
    priority=$(echo "$records_json" | jq -r ".[$idx].Priority // empty")

    record_menu_flow "$rid" "$rr" "$dm" "$rtype" "$val" "$priority"
}

# ============================================================
#  交互流程：DDNS 设置
# ============================================================

ddns_settings_flow() {
    while true; do
        local records="${DDNS_RECORDS:-（无）}"
        local cron_status
        is_cron_installed && cron_status="✅ 已安装" || cron_status="❌ 未安装"

        echo "DDNS 设置  [跟踪: $records]  [间隔: ${DDNS_INTERVAL}分钟]  [cron: $cron_status]"
        PS3="请选择 (1-4): "
        if is_cron_installed; then
            select action in "查看/修改跟踪记录" "修改检测间隔" "卸载 crontab" "返回"; do
                case $action in
                    "查看/修改跟踪记录")
                        if [ -z "$DDNS_RECORDS" ]; then
                            echo "当前没有跟踪的记录，请在新增或管理记录时开启定时更新"
                        else
                            echo "当前定时更新的记录:"
                            IFS=',' read -ra arr <<< "$DDNS_RECORDS"
                            local i=1
                            for r in "${arr[@]}"; do
                                echo "  $i. $r"
                                i=$((i+1))
                            done
                            read -p "输入要移除的 RR 名称（留空跳过）: " remove_rr
                            if [ -n "$remove_rr" ] && get_ddns_status "$remove_rr"; then
                                set_ddns_record "$remove_rr" 0
                                echo "📌 $remove_rr 已从定时更新列表移除"
                                [ -z "$DDNS_RECORDS" ] && uninstall_cron && echo "📌 已暂停 crontab 定时任务"
                            fi
                        fi
                        break;;

                    "修改检测间隔")
                        read -p "检测间隔（分钟，1~60）[${DDNS_INTERVAL}]: " new_interval
                        new_interval="${new_interval:-$DDNS_INTERVAL}"
                        if [ "$new_interval" -ge 1 ] 2>/dev/null && [ "$new_interval" -le 60 ] 2>/dev/null; then
                            DDNS_INTERVAL="$new_interval"
                            save_config
                            install_cron "$DDNS_INTERVAL"
                            echo "✅ 检测间隔已修改为 $DDNS_INTERVAL 分钟"
                        else
                            echo "❌ 请输入 1~60 之间的数字"
                        fi
                        break;;

                    "卸载 crontab")
                        if uninstall_cron; then
                            echo "✅ 已暂停 crontab 定时任务（已注释）"
                        else
                            echo "未找到相关 crontab 任务"
                        fi
                        break;;

                    "返回") return;;
                esac
            done
        else
            select action in "查看/修改跟踪记录" "修改检测间隔" "安装 crontab" "返回"; do
                case $action in
                    "查看/修改跟踪记录")
                        if [ -z "$DDNS_RECORDS" ]; then
                            echo "当前没有跟踪的记录，请在新增或管理记录时开启定时更新"
                        else
                            echo "当前定时更新的记录:"
                            IFS=',' read -ra arr <<< "$DDNS_RECORDS"
                            local i=1
                            for r in "${arr[@]}"; do
                                echo "  $i. $r"
                                i=$((i+1))
                            done
                        fi
                        break;;

                    "修改检测间隔")
                        read -p "检测间隔（分钟，1~60）[${DDNS_INTERVAL}]: " new_interval
                        new_interval="${new_interval:-$DDNS_INTERVAL}"
                        if [ "$new_interval" -ge 1 ] 2>/dev/null && [ "$new_interval" -le 60 ] 2>/dev/null; then
                            DDNS_INTERVAL="$new_interval"
                            save_config
                            echo "✅ 检测间隔已修改为 $DDNS_INTERVAL 分钟"
                        else
                            echo "❌ 请输入 1~60 之间的数字"
                        fi
                        break;;

                    "安装 crontab")
                        if [ -z "$DDNS_RECORDS" ]; then
                            echo "❌ 没有定时更新的记录，请先添加记录并开启定时更新"
                        else
                            install_cron "$DDNS_INTERVAL"
                            echo "✅ 已安装 crontab 定时任务，每 $DDNS_INTERVAL 分钟检测一次"
                        fi
                        break;;

                    "返回") return;;
                esac
            done
        fi
    done
}

# ============================================================
#  交互流程：主菜单
# ============================================================

main_menu() {
    while true; do
        echo
        echo "主菜单  [域名: $DOMAIN]"
        PS3="请选择 (1-6): "
        select action in "查看/管理解析记录" "新增解析记录" "切换域名" "重新配置 AccessKey" "DDNS 设置" "退出"; do
            case $action in
                "查看/管理解析记录") list_records_flow; break;;
                "新增解析记录") add_record_flow; break;;
                "切换域名")
                    read -p "输入新域名（如 example.com）[$DOMAIN]: " new_domain
                    new_domain="${new_domain:-$DOMAIN}"
                    DOMAIN="$new_domain"
                    save_config
                    echo "✅ 已切换到域名: $DOMAIN"
                    break;;
                "重新配置 AccessKey")
                    read -p "确认重新配置 AccessKey？所有 DNS 操作将使用新密钥 (y/N): " confirm
                    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                        local old_id="$ACCESS_KEY_ID" old_secret="$ACCESS_KEY_SECRET" old_domain="$DOMAIN"
                        if guide_config; then
                            echo "✅ 配置已更新"
                        else
                            ACCESS_KEY_ID="$old_id"
                            ACCESS_KEY_SECRET="$old_secret"
                            DOMAIN="$old_domain"
                            echo "重新配置取消，使用旧配置"
                        fi
                    fi
                    break;;
                "DDNS 设置") ddns_settings_flow; break;;
                "退出")
                    read -p "确认退出？(Y/n): " confirm
                    confirm="${confirm:-Y}"
                    if [ "$confirm" = "Y" ] || [ "$confirm" = "y" ]; then
                        echo "再见！"
                        exit 0
                    fi
                    break;;
                *) echo "无效选项"; break;;
            esac
        done
    done
}

# ============================================================
#  Watch 模式
# ============================================================

watch_mode() {
    if ! load_config; then
        echo "❌ 配置文件不存在或无效，请先运行交互模式配置"
        exit 1
    fi

    local ddns_arr=()
    IFS=',' read -ra ddns_arr <<< "$DDNS_RECORDS"
    [ ${#ddns_arr[@]} -eq 0 ] && { echo "未配置 DDNS 跟踪记录或域名"; exit 1; }

    local ip
    ip=$(get_public_ip) || { echo "❌ 获取公网 IP 失败"; exit 1; }
    echo "[ddnsman] $(date '+%Y-%m-%d %H:%M:%S')  公网 IP: $ip"

    local data
    data=$(get_records) || { echo "❌ 获取解析记录失败"; exit 1; }

    for rr in "${ddns_arr[@]}"; do
        local count rid val rtype priority
        count=$(echo "$data" | jq "[.DomainRecords.Record[] | select(.RR == \"$rr\")] | length" 2>/dev/null || echo 0)
        if [ "$count" -eq 0 ]; then
            echo "  ⚠️  $rr.$DOMAIN: 未在阿里云中找到此记录，跳过"
            continue
        fi

        rid=$(echo "$data" | jq -r ".DomainRecords.Record[] | select(.RR == \"$rr\") | .RecordId" 2>/dev/null)
        val=$(echo "$data" | jq -r ".DomainRecords.Record[] | select(.RR == \"$rr\") | .Value" 2>/dev/null)
        rtype=$(echo "$data" | jq -r ".DomainRecords.Record[] | select(.RR == \"$rr\") | .Type" 2>/dev/null)
        priority=$(echo "$data" | jq -r ".DomainRecords.Record[] | select(.RR == \"$rr\") | .Priority // empty" 2>/dev/null)

        local cached_ip
        cached_ip=$(load_ip_cache | grep "^$rr=" | cut -d= -f2)
        if [ "$cached_ip" = "$ip" ]; then
            echo "  $rr.$DOMAIN: IP 无变化 ($ip)"
            continue
        fi

        if update_dns_record "$rid" "$rr" "$rtype" "$ip" "$TTL" "$priority"; then
            echo "  ✅ $rr.$DOMAIN: ${cached_ip:-无} -> $ip"
            save_ip_cache "$rr" "$ip"
        else
            echo "  ❌ $rr.$DOMAIN: 更新失败"
        fi
    done
}

# ============================================================
#  入口
# ============================================================

case "${1:-}" in
    --watch)
        watch_mode
        ;;
    *)
        if ! load_config; then
            guide_config || exit 1
        fi
        main_menu
        ;;
esac
