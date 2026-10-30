#!/bin/bash
#=============================================================================
# 月度出向流量限制脚本（按阿里云 CDT 出方向流量口径）
#
# 依据：阿里云 CDT 公网流量免费额度为 220 GB/月，仅计"出方向"流量，
#       入方向流量不计费。因此本脚本只统计并限制网卡"出方向(tx)"流量。
#
# 逻辑：
#   1. 用 vnstat 统计网卡当月出方向(tx)流量；
#   2. 达到告警阈值(默认 90%)时触发告警；
#   3. 达到上限(默认 220GB)时，通过 iptables 丢弃出方向包（保留入站与回环），
#      实现"止血"；每月 1 号重置后自动恢复。
#
# 目标系统：CentOS 7/8/9、Rocky、Ubuntu 18/20/22/24
# 依赖：vnstat、iptables
#=============================================================================

#------------------------- 可配置项 -------------------------
IFACE="ens3"                 # 网卡名，务必按实际修改（ip -o link show 查看）
MONTHLY_LIMIT_GB=190         # 月度出向流量上限(GB)，香港非内地免费额度200GB，留10GB余量
WARN_PERCENT=90              # 达到该百分比时告警（未断流）
SSH_PORT=22                  # 断流时仍放行的管理端口（SSH），避免把自己锁死
NOTIFY_CMD=""                # 可选：告警命令，如 curl 钉钉/企业微信机器人
# 示例（钉钉机器人，把 MSG 替换为告警内容占位）：
# NOTIFY_CMD="curl -s 'https://oapi.dingtalk.com/robot/send?access_token=TOKEN' \
#   -H 'Content-Type: application/json' \
#   -d '{\"msgtype\":\"text\",\"text\":{\"content\":\"MSG\"}}'"

STATE_FILE="/var/run/traffic_limit_state"       # 状态文件（记录是否已断流）
MONTH_FILE="/var/run/traffic_limit_month"       # 记录上次运行所属月份（用于跨月自愈）
LOG_FILE="/var/log/traffic_limit.log"

# iptables 自定义链：出向断流用
CHAIN="TRAFFIC_OUT_LIMIT"
BLOCK_CHAIN="TRAFFIC_OUT_BLOCK"

log() { echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }

#------------------------- 读当月出向流量(MB) -------------------------
# 使用 vnstat --oneline 稳定输出（分号分隔），兼容 vnstat 1.x/2.x 的月份格式差异。
# oneline 示例（vnstat 2.9）：
# 1;ens3;2026-10-30;3.12 GiB;121.69 MiB;3.24 GiB;...;2026-10;3.12 GiB;121.69 MiB;3.24 GiB
# 最后 3 个字段为"当月累计"：rx / tx / total，每个字段形如"值 单位"（空格分隔）。
# 因此当月出向(tx) = 第 14 字段。
ONELINE=$(vnstat -m -i "$IFACE" --oneline 2>/dev/null)
if [ -z "$ONELINE" ]; then
    log "WARN: 无法从 vnstat 读取当月数据，脚本退出（不执行断流，避免误伤）"
    exit 0
fi

TX_FIELD=$(echo "$ONELINE" | awk -F';' '{print $14}')   # 当月出向，如 "121.69 MiB"
TX_STR=$(echo "$TX_FIELD" | awk '{print $1}')           # 值，如 121.69
TX_UNIT=$(echo "$TX_FIELD" | awk '{print $2}')          # 单位，如 MiB

# 数值/单位无效则安全退出，避免误断流
case "$TX_UNIT" in
    TiB|GiB|MiB|KiB|B) : ;;
    *) log "WARN: vnstat 输出解析异常（TX_FIELD=$TX_FIELD），脚本退出"; exit 0 ;;
esac

# 统一换算为 MB
case "$TX_UNIT" in
    TiB) TX_MB=$(awk "BEGIN{printf \"%.2f\", $TX_STR*1024*1024}") ;;
    GiB) TX_MB=$(awk "BEGIN{printf \"%.2f\", $TX_STR*1024}") ;;
    MiB) TX_MB=$(awk "BEGIN{printf \"%.2f\", $TX_STR}") ;;
    KiB) TX_MB=$(awk "BEGIN{printf \"%.2f\", $TX_STR/1024}") ;;
    B)   TX_MB=$(awk "BEGIN{printf \"%.2f\", $TX_STR/1024/1024}") ;;
    *)   TX_MB=0 ;;
esac

LIMIT_MB=$(awk "BEGIN{printf \"%.0f\", $MONTHLY_LIMIT_GB*1024}")
WARN_MB=$(awk "BEGIN{printf \"%.0f\", $LIMIT_MB*$WARN_PERCENT/100}")
TX_MB_INT=$(awk "BEGIN{printf \"%.0f\", $TX_MB}")

#------------------------- 跨月自愈 -------------------------
# 目的：无论每月 1 号 00:01 服务器是否在线，只要脚本下次运行，
#       就能检测到月份已变化并自动解除上月的断流状态。
# 原理：vnstat 按月自动切分（当前月 tx 会自动归零），
#       这里用 MONTH_FILE 记录上次运行月份，比对发现跨月即清理断流。
CUR_MONTH=$(date '+%Y-%m')
LAST_MONTH=""
[ -f "$MONTH_FILE" ] && LAST_MONTH=$(cat "$MONTH_FILE")

if [ "$LAST_MONTH" != "$CUR_MONTH" ]; then
    # 首次运行 或 已跨月：清理可能残留的断流状态
    if iptables -C OUTPUT -j "$CHAIN" 2>/dev/null; then
        iptables -D OUTPUT -j "$CHAIN" 2>/dev/null
        iptables -F "$CHAIN" 2>/dev/null
        iptables -F "$BLOCK_CHAIN" 2>/dev/null
        iptables -X "$CHAIN" 2>/dev/null
        iptables -X "$BLOCK_CHAIN" 2>/dev/null
        log "NEWMONTH: 检测到跨月（$LAST_MONTH -> $CUR_MONTH），已清理上月断流规则"
    fi
    rm -f "$STATE_FILE"
    echo "$CUR_MONTH" > "$MONTH_FILE"
fi

#------------------------- 主逻辑 -------------------------
BLOCKED=0
[ -f "$STATE_FILE" ] && BLOCKED=1

if [ "$TX_MB_INT" -ge "$LIMIT_MB" ]; then
    # 已达上限：执行断流（只丢出方向，但放行 SSH 管理端口，避免锁死）
    if [ "$BLOCKED" -eq 0 ]; then
        iptables -N "$CHAIN" 2>/dev/null
        iptables -F "$CHAIN"
        iptables -N "$BLOCK_CHAIN" 2>/dev/null
        iptables -F "$BLOCK_CHAIN"
        # 关键：先放行 SSH 管理端口（出向），确保断流后仍能远程登录恢复
        iptables -A "$BLOCK_CHAIN" -o "$IFACE" -p tcp --dport "$SSH_PORT" -j RETURN
        iptables -A "$BLOCK_CHAIN" -o "$IFACE" -p tcp --sport "$SSH_PORT" -j RETURN
        # 再丢弃其余出向流量
        iptables -A "$BLOCK_CHAIN" -o "$IFACE" -j DROP
        iptables -C OUTPUT -j "$CHAIN" 2>/dev/null || iptables -I OUTPUT 1 -j "$CHAIN"
        iptables -C "$CHAIN" -j "$BLOCK_CHAIN" 2>/dev/null || iptables -A "$CHAIN" -j "$BLOCK_CHAIN"
        echo 1 > "$STATE_FILE"
        log "LIMIT: 当月出向流量已达 ${MONTHLY_LIMIT_GB}GB(${TX_STR}${TX_UNIT})，已禁止出方向流量（SSH $SSH_PORT 已放行）"
        [ -n "$NOTIFY_CMD" ] && eval "$NOTIFY_CMD" 2>/dev/null
    fi
else
    # 未达上限：若之前断流过则恢复
    if [ "$BLOCKED" -eq 1 ]; then
        iptables -D OUTPUT -j "$CHAIN" 2>/dev/null
        iptables -F "$CHAIN" 2>/dev/null
        iptables -F "$BLOCK_CHAIN" 2>/dev/null
        rm -f "$STATE_FILE"
        log "RESTORE: 流量限制已解除"
        [ -n "$NOTIFY_CMD" ] && eval "$NOTIFY_CMD" 2>/dev/null
    fi

    # 达到告警阈值
    if [ "$TX_MB_INT" -ge "$WARN_MB" ]; then
        log "WARN: 当月出向流量 ${TX_STR}${TX_UNIT}，已达 ${WARN_PERCENT}%"
        [ -n "$NOTIFY_CMD" ] && eval "$NOTIFY_CMD" 2>/dev/null
    fi
fi

exit 0
