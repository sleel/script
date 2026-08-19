#!/bin/sh
# WireGuard Watchdog for OpenWrt v2.1.0 (IPv6-only, resolveip-only)
# 状态机 + 断路器：DDNS漂移热更新 -> ping唤醒NAT -> 硬重启，失败达阈值后静默保护
# 用途：主服务器切换到 IPv6 时使用（例如运营商封锁 IPv4 时的备用方案）

WG_IF="wg0"
THRESHOLD=600          # 无握手超过此秒数视为异常
PING_HOST="10.0.198.1" # 对端隧道内网地址（隧道内部地址，与端点IP族无关）

# !!! 必须替换为真实值，否则启动即拒绝运行 !!!
DDNS_DOMAIN="your-ddns-domain.example.com"
ENDPOINT_PORT="51820"  # 1-65535

SKIP_AFTER_ACTION=240  # 动作后冷却期(秒)，避免同一异常被重复处理
MAX_FAILURES=10        # 触发静默保护前允许的最大连续失败次数
SILENCE_DURATION=3600  # 静默保护时长(秒)
CMD_TIMEOUT=8          # 外部命令超时保护(秒)，防止链路异常时脚本卡死

# 状态文件加 -v6 后缀，避免和 wg-watchdog-v4.sh 的状态互相干扰
LOCKDIR="/tmp/wg-watchdog-${WG_IF}-v6.lock"
LAST_ACTION_FILE="/tmp/wg-watchdog-last-action-${WG_IF}-v6"
FAIL_COUNT_FILE="/tmp/wg-watchdog-failcount-${WG_IF}-v6"
SILENCE_TS_FILE="/tmp/wg-watchdog-silence-${WG_IF}-v6"

now=$(date +%s)

TIMEOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout ${CMD_TIMEOUT}"

log() { logger -t "wg-watchdog-v6" "$1"; }

atomic_write() {
    local val="$1" file="$2"
    echo "$val" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

clear_fail_state() {
    rm -f "$FAIL_COUNT_FILE" "$SILENCE_TS_FILE" "${FAIL_COUNT_FILE}.tmp" "${SILENCE_TS_FILE}.tmp"
}

# 从 "[IPv6]:PORT" 提取纯 IPv6（兼容无端点时的 "(none)"/空值原样返回）
extract_ip() {
    case "$1" in
        \[*\]:*) echo "$1" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/' ;;
        *)       echo "$1" ;;
    esac
}

# IPv6 公网合法性校验：黑名单排除回环/链路本地/ULA/多播/文档段/IPv4映射地址
is_public_ip() {
    local ip
    ip=$(echo "$1" | tr 'A-F' 'a-f')
    case "$ip" in
        *[!0-9a-f:]*) return 1 ;;   # 含非法字符
        *:*) : ;;                    # 必须含冒号
        *) return 1 ;;
    esac
    case "$ip" in
        ::|::1) return 1 ;;              # 未指定地址 / 回环
        fe8*|fe9*|fea*|feb*) return 1 ;; # fe80::/10 链路本地
        fc*|fd*) return 1 ;;             # fc00::/7 唯一本地地址(ULA)
        ff*) return 1 ;;                 # ff00::/8 多播
        2001:db8:*|2001:db8) return 1 ;; # 2001:db8::/32 文档/测试网段
        ::ffff:*) return 1 ;;            # IPv4-mapped 地址
        100::*) return 1 ;;              # 100::/64 Discard-Only
        *) return 0 ;;
    esac
}

# 启动校验：拒绝占位符/非法配置
if [ "$DDNS_DOMAIN" = "your-ddns-domain.example.com" ] || [ -z "$DDNS_DOMAIN" ]; then
    log "CONFIG ERROR: DDNS_DOMAIN 未配置或仍为占位符。Exit."
    exit 1
fi
case "$ENDPOINT_PORT" in
    ''|*[!0-9]*) log "CONFIG ERROR: ENDPOINT_PORT 非数字。Exit."; exit 1 ;;
esac
if [ "$ENDPOINT_PORT" -lt 1 ] || [ "$ENDPOINT_PORT" -gt 65535 ]; then
    log "CONFIG ERROR: ENDPOINT_PORT 超出 1-65535 范围。Exit."
    exit 1
fi

# 并发锁（含陈旧锁自愈）
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    stale=0
    if [ -f "$LOCKDIR/pid" ]; then
        lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
        case "$lock_pid" in ''|*[!0-9]*) lock_pid="" ;; esac
        [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null && stale=1
    fi
    if [ "$stale" -eq 1 ]; then
        log "WARNING: 检测到陈旧锁(PID $lock_pid 已不存在)，强制清理重试。"
        rm -rf "$LOCKDIR"
        mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR"' EXIT

# 接口可用性检查
if ! ip link show "$WG_IF" >/dev/null 2>&1 || ! $TIMEOUT_CMD wg show "$WG_IF" >/dev/null 2>&1; then
    log "Interface '$WG_IF' unavailable. Exit."
    exit 1
fi

# 动作冷却期检查（含 NTP 回拨保护）
if [ -f "$LAST_ACTION_FILE" ]; then
    last_action=$(cat "$LAST_ACTION_FILE")
    case "$last_action" in ''|*[!0-9]*) last_action=0 ;; esac
    [ "$now" -lt "$last_action" ] && last_action=0
    [ $((now - last_action)) -lt "$SKIP_AFTER_ACTION" ] && exit 0
fi

# 获取基准握手状态
peer_info=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null | head -n 1)
if [ -z "$peer_info" ]; then
    log "No peer found on '$WG_IF'. Exit."
    exit 0
fi
pubkey=$(echo "$peer_info" | awk '{print $1}')
latest_handshake=$(echo "$peer_info" | awk '{print $2}')
case "$latest_handshake" in ''|*[!0-9]*) latest_handshake=0 ;; esac

if [ "$latest_handshake" -eq 0 ]; then
    age=$((THRESHOLD + 1))
elif [ "$latest_handshake" -gt "$now" ]; then
    age=0  # NTP 回拨，保守认定为刚握手过
else
    age=$((now - latest_handshake))
fi

if [ "$age" -le "$THRESHOLD" ]; then
    clear_fail_state
    exit 0
fi

# === 异常恢复流程 ===

# 断路器静默检查：提前到最前面，静默期内跳过全部 DNS/ping/重启动作
silence_ts=0
[ -f "$SILENCE_TS_FILE" ] && silence_ts=$(cat "$SILENCE_TS_FILE")
case "$silence_ts" in ''|*[!0-9]*) silence_ts=0 ;; esac
[ "$now" -lt "$silence_ts" ] && silence_ts=0

if [ "$silence_ts" -gt 0 ]; then
    if [ $((now - silence_ts)) -lt "$SILENCE_DURATION" ]; then
        remaining=$((SILENCE_DURATION - (now - silence_ts)))
        log "Circuit breaker OPEN (${remaining}s remaining). Skipping recovery."
        atomic_write "$now" "$LAST_ACTION_FILE"
        exit 0
    else
        log "Circuit breaker expired. Resetting failure state."
        clear_fail_state
    fi
fi

log "Peer $pubkey stale (age=${age}s). Initiating recovery..."

keepalive=$($TIMEOUT_CMD wg show "$WG_IF" persistent-keepalive 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
if [ -z "$keepalive" ] || [ "$keepalive" = "off" ]; then
    log "WARNING: PersistentKeepalive disabled for $pubkey!"
fi

# --- Phase 1: DDNS 漂移检测与热更新（IPv6，单一方法 resolveip -6） ---
current_endpoint=$($TIMEOUT_CMD wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
current_ip=$(extract_ip "$current_endpoint")

real_ip=$($TIMEOUT_CMD resolveip -6 -t 3 "$DDNS_DOMAIN" 2>/dev/null | head -n 1)

if [ -n "$real_ip" ] && ! is_public_ip "$real_ip"; then
    log "WARNING: DNS returned invalid/private IP ($real_ip). Ignoring."
    real_ip=""
fi

if [ -n "$real_ip" ] && [ "$current_ip" != "$real_ip" ]; then
    log "Phase 1: DDNS drift detected. Updating $current_ip -> $real_ip"
    if $TIMEOUT_CMD wg set "$WG_IF" peer "$pubkey" endpoint "[${real_ip}]:${ENDPOINT_PORT}"; then
        new_endpoint=$($TIMEOUT_CMD wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
        new_ip=$(extract_ip "$new_endpoint")
        if [ "$new_ip" = "$real_ip" ]; then
            sleep 10
        else
            log "Phase 1: Endpoint verification failed (Expected $real_ip, Got $new_ip)."
        fi
    else
        log "Phase 1: wg endpoint update failed."
    fi
else
    if [ -z "$real_ip" ]; then
        log "Phase 1 skipped: DDNS resolve failed."
    else
        log "Phase 1 skipped: Endpoint IP unchanged ($real_ip)."
    fi
fi

new_handshake=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$new_handshake" in ''|*[!0-9]*) new_handshake=0 ;; esac
if [ "$new_handshake" -gt "$latest_handshake" ]; then
    log "Recovery SUCCESS: Phase 1 (DDNS_CHANGE, $current_ip -> $real_ip)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
    exit 0
fi

# --- Phase 2: Ping 唤醒 UDP/NAT ---
if ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1; then sleep 5; else sleep 2; fi

new_handshake_2=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$new_handshake_2" in ''|*[!0-9]*) new_handshake_2=0 ;; esac
if [ "$new_handshake_2" -gt "$latest_handshake" ]; then
    log "Recovery SUCCESS: Phase 2 (NAT_WAKEUP, ping $PING_HOST)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
    exit 0
fi

# --- Phase 3: 硬重启（无条件计入失败次数，避免 DDNS 持续漂移绕过断路器） ---
log "Phase 3: Hard restarting interface '$WG_IF'..."
$TIMEOUT_CMD ifdown "$WG_IF" || log "WARNING: Interface $WG_IF down failed."
sleep 3
$TIMEOUT_CMD ifup "$WG_IF" || log "ERROR: Interface $WG_IF restart failed."
sleep 15

verify_handshake=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$verify_handshake" in ''|*[!0-9]*) verify_handshake=0 ;; esac

if [ "$verify_handshake" -gt "$latest_handshake" ]; then
    log "Recovery SUCCESS: Phase 3 (HARD_RESTART_IFACE)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
else
    log "WARNING: Handshake STILL NOT restored after all phases."
    ip link show "$WG_IF" >/dev/null 2>&1 && atomic_write "$(date +%s)" "$LAST_ACTION_FILE"

    fail_count=0
    [ -f "$FAIL_COUNT_FILE" ] && fail_count=$(cat "$FAIL_COUNT_FILE")
    case "$fail_count" in ''|*[!0-9]*) fail_count=0 ;; esac
    fail_count=$((fail_count + 1))
    atomic_write "$fail_count" "$FAIL_COUNT_FILE"

    if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
        log "CRITICAL: Reached $MAX_FAILURES failures. Entering silent protection."
        atomic_write "$(date +%s)" "$SILENCE_TS_FILE"
    else
        log "Phase 3: Hard restart failed. Failure count: $fail_count/$MAX_FAILURES."
    fi
fi

exit 0
