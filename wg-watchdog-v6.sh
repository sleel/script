#!/bin/sh
# WireGuard Watchdog for OpenWrt v2.2.0 (IPv6-only, resolveip-only, lock self-heal hardened)
# 状态机 + 断路器：DDNS漂移热更新 -> ping唤醒NAT -> 硬重启，失败达阈值后静默保护
# 用途：主服务器切换到 IPv6 时使用（例如运营商封锁 IPv4 时的备用方案）

WG_IF="wg0"
THRESHOLD=300
PING_HOST="10.0.198.1"

DDNS_DOMAIN="your-ddns-domain.example.com"
ENDPOINT_PORT="51820"

SKIP_AFTER_ACTION=240
MAX_FAILURES=10
SILENCE_DURATION=3600
CMD_TIMEOUT=8
LOCK_MAX_AGE=60   # [新增] 锁目录最大存活时长(秒)，超过视为陈旧锁，不依赖pid文件是否存在

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

extract_ip() {
    case "$1" in
        \[*\]:*) echo "$1" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/' ;;
        *)       echo "$1" ;;
    esac
}

is_public_ip() {
    local ip
    ip=$(echo "$1" | tr 'A-F' 'a-f')
    case "$ip" in
        *[!0-9a-f:]*) return 1 ;;
        *:*) : ;;
        *) return 1 ;;
    esac
    case "$ip" in
        ::|::1) return 1 ;;
        fe8*|fe9*|fea*|feb*) return 1 ;;
        fc*|fd*) return 1 ;;
        ff*) return 1 ;;
        2001:db8:*|2001:db8) return 1 ;;
        ::ffff:*) return 1 ;;
        100::*) return 1 ;;
        *) return 0 ;;
    esac
}

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
# [修复] 陈旧判定不再要求 pid 文件必须存在——优先用锁目录自身的存活时长判断，
# 避免"进程在写 pid 文件前被杀死"导致锁永久残留、后续每次都静默退出的死锁。
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    stale=0
    lock_mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null)
    case "$lock_mtime" in ''|*[!0-9]*) lock_mtime="" ;; esac
    if [ -z "$lock_mtime" ]; then
        lock_mtime=$(date -r "$LOCKDIR" +%s 2>/dev/null)
        case "$lock_mtime" in ''|*[!0-9]*) lock_mtime=0 ;; esac
    fi
    lock_age=$((now - lock_mtime))
    [ "$lock_age" -lt 0 ] && lock_age=0

    if [ "$lock_mtime" -eq 0 ] || [ "$lock_age" -ge "$LOCK_MAX_AGE" ]; then
        stale=1
    elif [ -f "$LOCKDIR/pid" ]; then
        lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
        case "$lock_pid" in ''|*[!0-9]*) lock_pid="" ;; esac
        [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null && stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        log "WARNING: 检测到陈旧锁(age=${lock_age}s)，强制清理重试。"
        rm -rf "$LOCKDIR"
        mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR"' EXIT

if ! ip link show "$WG_IF" >/dev/null 2>&1 || ! $TIMEOUT_CMD wg show "$WG_IF" >/dev/null 2>&1; then
    log "Interface '$WG_IF' unavailable. Exit."
    exit 1
fi

if [ -f "$LAST_ACTION_FILE" ]; then
    last_action=$(cat "$LAST_ACTION_FILE")
    case "$last_action" in ''|*[!0-9]*) last_action=0 ;; esac
    [ "$now" -lt "$last_action" ] && last_action=0
    [ $((now - last_action)) -lt "$SKIP_AFTER_ACTION" ] && exit 0
fi

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
    age=0
else
    age=$((now - latest_handshake))
fi

if [ "$age" -le "$THRESHOLD" ]; then
    clear_fail_state
    exit 0
fi

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

if ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1; then sleep 5; else sleep 2; fi

new_handshake_2=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
case "$new_handshake_2" in ''|*[!0-9]*) new_handshake_2=0 ;; esac
if [ "$new_handshake_2" -gt "$latest_handshake" ]; then
    log "Recovery SUCCESS: Phase 2 (NAT_WAKEUP, ping $PING_HOST)"
    atomic_write "$(date +%s)" "$LAST_ACTION_FILE"
    clear_fail_state
    exit 0
fi

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
