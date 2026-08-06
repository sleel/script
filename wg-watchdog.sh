#!/bin/sh
# WireGuard Watchdog for OpenWrt
# Version: 1.1.2 LTS (State Machine & Circuit Breaker with CGNAT/Time-Travel Fix)
# Target: Single Peer Client, PPPoE/DDNS Environment

WG_IF="wg0"
THRESHOLD=600                   # 超过 10 分钟无握手认为异常
PING_HOST="10.0.198.1"          # 对端 WireGuard 隧道内网地址
DDNS_DOMAIN="cctv.com"          # 远端动态域名
ENDPOINT_PORT="88888"           # 远端 WireGuard 监听端口

# 核心时间与重试参数
SKIP_AFTER_ACTION=240           # 动作执行后跳过检测时间（4分钟），避开cron耗时陷阱
MAX_FAILURES=10                 # 触发静默保护前的最大允许硬重启失败次数
SILENCE_DURATION=3600           # 连续最大失败后的静默保护时间（1小时/3600秒）

# 接口级状态文件，完美支持未来多接口扩展
LOCKDIR="/tmp/wg-watchdog-${WG_IF}.lock" 
LAST_ACTION_FILE="/tmp/wg-watchdog-last-action-${WG_IF}"
FAIL_COUNT_FILE="/tmp/wg-watchdog-failcount-${WG_IF}"
SILENCE_TS_FILE="/tmp/wg-watchdog-silence-${WG_IF}"

# 获取脚本启动初始时间，仅用于动作冷却比对
now=$(date +%s)

log() {
    logger -t "wg-watchdog" "$1"
}

# 辅助函数：原子写入，防止断电导致的文件损坏空洞
atomic_write() {
    local val="$1"
    local file="$2"
    echo "$val" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

# 辅助函数：连接恢复时，清空失败计数器和静默状态
clear_fail_state() {
    rm -f "$FAIL_COUNT_FILE" "$SILENCE_TS_FILE" "${FAIL_COUNT_FILE}.tmp" "${SILENCE_TS_FILE}.tmp"
}

# 辅助函数：公网 IP 合法性过滤 (防御 DNS 污染/内网劫持/CGNAT/RFC2544)
is_public_ip() {
    local ip="$1"
    # 基础格式过滤，并排除 A/B/C 类局域网、回环、CGNAT、测试网等保留网段
    echo "$ip" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | \
    grep -E -v \
'^(10|127|169\.254|192\.168|0|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])|192\.0\.2|198\.(1[89]|51\.100)|203\.0\.113|224|239|255)\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' >/dev/null 2>&1
}

# 1. 接口级并发锁
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
fi
trap 'rm -rf "$LOCKDIR"' EXIT

# 2. 接口可用性检查
if ! ip link show "$WG_IF" >/dev/null 2>&1 || ! wg show "$WG_IF" >/dev/null 2>&1; then
    log "Interface '$WG_IF' unavailable. Exit."
    exit 1
fi

# 3. 动作冷却期检查 (含 NTP 时间回拨保护)
if [ -f "$LAST_ACTION_FILE" ]; then
    last_action=$(cat "$LAST_ACTION_FILE")
    case "$last_action" in ''|*[!0-9]*) last_action=0 ;; esac
    [ "$now" -lt "$last_action" ] && last_action=0  # NTP 穿越保护
    
    if [ $((now - last_action)) -lt "$SKIP_AFTER_ACTION" ]; then
        exit 0
    fi
fi

# 4. 获取并计算初始握手状态 (作为后续比对的基准)
peer_info=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | head -n 1)

if [ -z "$peer_info" ]; then
    log "No peer found on '$WG_IF'. Exit."
    exit 0
fi

pubkey=$(echo "$peer_info" | awk '{print $1}')
latest_handshake=$(echo "$peer_info" | awk '{print $2}')

case "$latest_handshake" in ''|*[!0-9]*) latest_handshake=0 ;; esac

# [终极优化]：NTP 时间穿越(Time-Travel)保护与初始状态逻辑
if [ "$latest_handshake" -eq 0 ]; then
    age=$((THRESHOLD + 1))
elif [ "$latest_handshake" -gt "$now" ]; then
    # 发生 NTP 回拨，握手时间在“未来”，保守认定为刚握手过 (age=0)
    age=0
else
    age=$((now - latest_handshake))
fi

# 如果网络正常，清空一切失败记录并退出
if [ "$age" -le "$THRESHOLD" ]; then
    clear_fail_state
    exit 0
fi

# === 以下为异常恢复流程 ===

log "Peer $pubkey stale (age=${age}s). Initiating recovery..."

# [优化]：在确定发生异常后才检查 Keepalive，消除正常期间的冗余日志噪声
keepalive=$(wg show "$WG_IF" persistent-keepalive 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
if [ -z "$keepalive" ] || [ "$keepalive" = "off" ]; then
    log "WARNING: PersistentKeepalive is disabled for $pubkey! Recovery may be delayed."
fi

# --- Phase 1: DDNS 漂移检测与热更新 ---
current_endpoint=$(wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
current_ip=$(echo "$current_endpoint" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/;s/:[0-9]+$//')

# 强制向公网权威 DNS 请求最新 IP，完美避开本地缓存
real_ip=$(nslookup "$DDNS_DOMAIN" 223.5.5.5 2>/dev/null \
| awk '/^Address/ {print $NF}' \
| grep -E '^[0-9]+\.' \
| tail -n1)

if [ -z "$real_ip" ]; then
    real_ip=$(resolveip -4 -t 3 "$DDNS_DOMAIN" 2>/dev/null | head -n 1)
fi

# DNS 合法性过滤
if [ -n "$real_ip" ]; then
    if ! is_public_ip "$real_ip"; then
        log "WARNING: DNS returned invalid/private IP ($real_ip). Ignoring."
        real_ip=""
    fi
fi

if [ -n "$real_ip" ] && [ "$current_ip" != "$real_ip" ]; then
    log "Phase 1: DDNS drift detected. Updating $current_ip -> $real_ip"
    
    if wg set "$WG_IF" peer "$pubkey" endpoint "${real_ip}:${ENDPOINT_PORT}"; then
        # 回读内核状态验证
        new_endpoint=$(wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
        new_ip=$(echo "$new_endpoint" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/;s/:[0-9]+$//')
        if [ "$new_ip" = "$real_ip" ]; then
            sleep 10 # 动态公网环境下，给予重建足够的宽限期
        else
            log "Phase 1: Endpoint verification failed (Expected $real_ip, Got $new_ip)."
        fi
    else
        log "Phase 1: wg endpoint update failed."
    fi
else
    if [ -z "$real_ip" ]; then
        log "Phase 1 skipped: DDNS resolve failed for $DDNS_DOMAIN."
    else
        log "Phase 1 skipped: Endpoint IP unchanged ($real_ip)."
    fi
fi

# 严格校验：比对基准握手时间
new_handshake=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$new_handshake" in ''|*[!0-9]*) new_handshake=0 ;; esac

if [ "$new_handshake" -gt "$latest_handshake" ]; then
    # 诊断级日志输出 & 实时时间戳写入
    log "Recovery SUCCESS: Phase 1 (Reason=DDNS_CHANGE, Old_IP=$current_ip, New_IP=$real_ip)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
    exit 0
fi

# --- Phase 2: Ping 唤醒 UDP/NAT ---
if ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1; then
    sleep 5
else
    sleep 2
fi

new_handshake_2=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$new_handshake_2" in ''|*[!0-9]*) new_handshake_2=0 ;; esac

if [ "$new_handshake_2" -gt "$latest_handshake" ]; then
    log "Recovery SUCCESS: Phase 2 (Reason=NAT_WAKEUP, Ping to $PING_HOST)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
    exit 0
fi

# --- Phase 3: 接口硬重启 (加入 5 次容错 + 1小时静默断路器) ---
do_hard_restart=1

if [ -z "$real_ip" ] || [ "$current_ip" = "$real_ip" ]; then
    silence_ts=0
    [ -f "$SILENCE_TS_FILE" ] && silence_ts=$(cat "$SILENCE_TS_FILE")
    case "$silence_ts" in ''|*[!0-9]*) silence_ts=0 ;; esac
    [ "$now" -lt "$silence_ts" ] && silence_ts=0
    
    if [ "$silence_ts" -gt 0 ]; then
        if [ $((now - silence_ts)) -lt "$SILENCE_DURATION" ]; then
            # 静默期内仅刷新冷却时间，彻底闭嘴
            atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
            do_hard_restart=0
        else
            log "Phase 3: 1-hour silent protection expired. Resetting failure count and retrying."
            clear_fail_state
        fi
    fi
fi

if [ "$do_hard_restart" -eq 1 ]; then
    log "Phase 3: Hard restarting interface '$WG_IF'..."
    
    if ! ifdown "$WG_IF"; then
        log "WARNING: Interface $WG_IF down failed."
    fi

    sleep 3

    if ! ifup "$WG_IF"; then
        log "ERROR: Interface $WG_IF restart failed."
    fi
    
    sleep 15
    
    verify_handshake=$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
    case "$verify_handshake" in ''|*[!0-9]*) verify_handshake=0 ;; esac

    if [ "$verify_handshake" -gt "$latest_handshake" ]; then
        log "Recovery SUCCESS: Phase 3 (Reason=HARD_RESTART_IFACE)"
        atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
        clear_fail_state
    else
        log "WARNING: Handshake STILL NOT restored after all phases."
        if ip link show "$WG_IF" >/dev/null 2>&1; then
             atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
        fi
        
        if [ -z "$real_ip" ] || [ "$current_ip" = "$real_ip" ]; then
            fail_count=0
            [ -f "$FAIL_COUNT_FILE" ] && fail_count=$(cat "$FAIL_COUNT_FILE")
            case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
            
            fail_count=$((fail_count + 1))
            atomic_write "$fail_count" "$FAIL_COUNT_FILE"
            
            if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
                log "CRITICAL: Reached $MAX_FAILURES consecutive failures. Entering 1-hour silent protection."
                atomic_write "$(date +%s)" "$SILENCE_TS_FILE"
            else
                log "Phase 3: Hard restart failed. Failure count: $fail_count/$MAX_FAILURES."
            fi
        fi
    fi
fi

exit 0