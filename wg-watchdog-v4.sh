#!/bin/sh
# WireGuard Watchdog for OpenWrt v2.2.2 (IPv4-only, lock self-heal hardened)
# 状态机 + 断路器：DDNS漂移热更新 -> ping唤醒NAT -> 硬重启，失败达阈值后静默保护
# 用途：主服务器走 IPv4 时使用；若运营商封锁 IPv4，请切换到 wg-watchdog-v6.sh

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

WG_IF="wg0"
THRESHOLD=300            # 无握手超过此秒数视为异常
PING_HOST="10.0.198.1"   # 对端隧道内网地址（隧道内部地址，与端点IP族无关）

# !!! 必须替换为真实值，否则启动即拒绝运行 !!!
DDNS_DOMAIN="cctv.com"
ENDPOINT_PORT="8888"    # 1-65535
DNS_SERVER="223.5.5.5"   # 用于解析 DDNS 的上游 DNS（公网 IPv4），可按需替换

SKIP_AFTER_ACTION=240    # 动作后冷却期(秒)，避免同一异常被重复处理
MAX_FAILURES=10          # 触发静默保护前允许的最大连续失败次数
SILENCE_DURATION=3600    # 静默保护时长(秒)
CMD_TIMEOUT=8            # 外部命令超时保护(秒)，防止链路异常时脚本卡死
LOCK_MAX_AGE=240         # 锁目录最大存活时长(秒)，需覆盖最坏运行时长（约170s）

LOCKDIR="/tmp/wg-watchdog-${WG_IF}.lock"
LAST_ACTION_FILE="/tmp/wg-watchdog-last-action-${WG_IF}"
FAIL_COUNT_FILE="/tmp/wg-watchdog-failcount-${WG_IF}"
SILENCE_TS_FILE="/tmp/wg-watchdog-silence-${WG_IF}"

now=$(date +%s)

TIMEOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_CMD="timeout ${CMD_TIMEOUT}"

log() { logger -t "wg-watchdog-v4" "$1"; }

atomic_write() {
    local val="$1" file="$2"
    echo "$val" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

clear_fail_state() {
    rm -f "$FAIL_COUNT_FILE" "$SILENCE_TS_FILE" "${FAIL_COUNT_FILE}.tmp" "${SILENCE_TS_FILE}.tmp"
}

# 从 "IP:PORT" 提取纯 IP（本脚本只处理 IPv4 端点）
extract_ip() {
    echo "$1" | sed -E 's/:[0-9]+$//'
}

# IPv4 公网合法性校验：格式 + 数值范围(0-255) + 排除私有/CGNAT/保留段
is_public_ip() {
    local ip="$1" o1 o2 o3 o4
    echo "$ip" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null 2>&1 || return 1
    o1=$(echo "$ip" | cut -d. -f1); o2=$(echo "$ip" | cut -d. -f2)
    o3=$(echo "$ip" | cut -d. -f3); o4=$(echo "$ip" | cut -d. -f4)
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    echo "$ip" | grep -E -v \
        '^(10|127|169\.254|192\.168|0|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])|192\.0\.2|198\.(1[89]|51\.100)|203\.0\.113|22[4-9]|23[0-9]|24[0-9]|25[0-5])\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' \
        >/dev/null 2>&1
}

# 解析 DDNS：优先 resolveip（OpenWrt 原生，走系统解析），nslookup 兜底且只取
# "Name:" 之后的 Address 行，避免 NXDOMAIN/超时时把 BusyBox nslookup 打印的
# 服务器自身地址误当成解析结果
resolve_ddns() {
    local ip=""
    ip=$($TIMEOUT_CMD resolveip -4 -t 3 "$DDNS_DOMAIN" 2>/dev/null | head -n 1)
    if [ -z "$ip" ]; then
        ip=$($TIMEOUT_CMD nslookup "$DDNS_DOMAIN" "$DNS_SERVER" 2>/dev/null \
            | awk '/^Name:/{f=1} f && /^Address/ {print $NF}' \
            | grep -E '^[0-9]+\.' | tail -n1)
    fi
    echo "$ip"
}

# 读取锁目录 mtime 并计算锁龄（结果写入全局 lock_mtime / lock_age）
get_lock_age() {
    lock_mtime=$(stat -c %Y "$LOCKDIR" 2>/dev/null)
    case "$lock_mtime" in ''|*[!0-9]*) lock_mtime="" ;; esac
    if [ -z "$lock_mtime" ]; then
        lock_mtime=$(date -r "$LOCKDIR" +%s 2>/dev/null)
        case "$lock_mtime" in ''|*[!0-9]*) lock_mtime=0 ;; esac
    fi
    lock_age=$((now - ${lock_mtime:-0}))
    [ "$lock_age" -lt 0 ] && lock_age=0
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
if ! is_public_ip "$DNS_SERVER"; then
    log "CONFIG ERROR: DNS_SERVER ($DNS_SERVER) 须为公网 IPv4。Exit."
    exit 1
fi

# 并发锁（陈旧锁自愈：存活+年龄双条件）
# - pid 存活且锁龄 <  LOCK_MAX_AGE -> 新鲜锁，退出
# - pid 存活但锁龄 >= LOCK_MAX_AGE -> 僵死或 pid 复用：cmdline 确为看门狗才 kill，否则仅清锁
# - pid 已死                       -> 陈旧，直接清理
# - pid 文件缺失/为空/非法         -> 回退到锁龄判定（覆盖 mkdir 后、写 pid 前被杀的窗口）
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    stale=0
    lock_pid=""
    [ -f "$LOCKDIR/pid" ] && lock_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    case "$lock_pid" in ''|*[!0-9]*) lock_pid="" ;; esac

    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        get_lock_age
        if [ "$lock_age" -ge "$LOCK_MAX_AGE" ]; then
            if tr '\0' ' ' < "/proc/$lock_pid/cmdline" 2>/dev/null | grep -q "wg-watchdog"; then
                log "WARNING: 活锁超龄(pid=$lock_pid age=${lock_age}s)且确为看门狗进程，kill 后清理。"
                kill "$lock_pid" 2>/dev/null
                sleep 1
                kill -9 "$lock_pid" 2>/dev/null
            else
                log "WARNING: 锁超龄(age=${lock_age}s)但 pid=$lock_pid 已复用为非看门狗进程，仅清理锁。"
            fi
            stale=1
        fi
    elif [ -n "$lock_pid" ]; then
        stale=1
    else
        get_lock_age
        { [ "$lock_mtime" -eq 0 ] || [ "$lock_age" -ge "$LOCK_MAX_AGE" ]; } && stale=1
    fi

    if [ "$stale" -eq 1 ]; then
        log "WARNING: 检测到陈旧锁，强制清理重试。"
        rm -rf "$LOCKDIR"
        mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
chmod 700 "$LOCKDIR" 2>/dev/null
echo $$ > "$LOCKDIR/pid" 2>/dev/null
# 属主确认：若 1s 后 pid 文件已不是本进程，说明锁被并发实例抢走，退出
sleep 1
[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] || exit 0
# trap 带属主校验：只有 pid 仍是本进程时才删除锁目录
trap '[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKDIR"' EXIT

# 接口可用性检查：先尝试自愈一次，而非直接躺平
if ! ip link show "$WG_IF" >/dev/null 2>&1; then
    log "WARNING: Interface '$WG_IF' missing. Attempting ifup..."
    $TIMEOUT_CMD ifup "$WG_IF" >/dev/null 2>&1
    sleep 3
fi
if ! ip link show "$WG_IF" >/dev/null 2>&1 || ! $TIMEOUT_CMD wg show "$WG_IF" >/dev/null 2>&1; then
    log "ERROR: Interface '$WG_IF' unavailable after self-heal attempt. Exit."
    exit 1
fi

# 动作冷却期检查（含 NTP 回拨保护）
if [ -f "$LAST_ACTION_FILE" ]; then
    last_action=$(cat "$LAST_ACTION_FILE")
    case "$last_action" in ''|*[!0-9]*) last_action=0 ;; esac
    [ "$now" -lt "$last_action" ] && last_action=0
    [ $((now - last_action)) -lt "$SKIP_AFTER_ACTION" ] && exit 0
fi

# 获取基准握手状态：遍历全部 peer，取最陈旧者，避免多 peer 场景下漏检
all_peers=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null)
if [ -z "$all_peers" ]; then
    log "No peer found on '$WG_IF'. Exit."
    exit 0
fi

pubkey=""
latest_handshake=0
age=-1
worst_age=-1
IFS='
'
for line in $all_peers; do
    p=$(echo "$line" | awk '{print $1}')
    h=$(echo "$line" | awk '{print $2}')
    case "$h" in ''|*[!0-9]*) h=0 ;; esac
    if [ "$h" -eq 0 ]; then
        a=$((THRESHOLD + 1))
    elif [ "$h" -gt "$now" ]; then
        a=0    # NTP 回拨，保守认定为刚握手过
    else
        a=$((now - h))
    fi
    if [ "$a" -gt "$worst_age" ]; then
        worst_age="$a"
        pubkey="$p"
        latest_handshake="$h"
        age="$a"
    fi
done
unset IFS

if [ "$age" -le "$THRESHOLD" ]; then
    clear_fail_state
    exit 0
fi

# === 异常恢复流程 ===

# 断路器静默检查：静默期内跳过全部 DNS/ping/重启动作
silence_ts=0
[ -f "$SILENCE_TS_FILE" ] && silence_ts=$(cat "$SILENCE_TS_FILE")
case "$silence_ts" in ''|*[!0-9]*) silence_ts=0 ;; esac
[ "$now" -lt "$silence_ts" ] && silence_ts=0

if [ "$silence_ts" -gt 0 ]; then
    if [ $((now - silence_ts)) -lt "$SILENCE_DURATION" ]; then
        remaining=$((SILENCE_DURATION - (now - silence_ts)))
        log "Circuit breaker OPEN (${remaining}s remaining). Skipping recovery."
        exit 0
    else
        log "Circuit breaker expired. Resetting failure state."
        clear_fail_state
    fi
fi

# 刷新时间基准：锁获取、ifup 自愈等前置步骤可能已耗时数秒
now=$(date +%s)

log "Peer $pubkey stale (age=${age}s). Initiating recovery..."

keepalive=$($TIMEOUT_CMD wg show "$WG_IF" persistent-keepalive 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
if [ -z "$keepalive" ] || [ "$keepalive" = "off" ]; then
    log "WARNING: PersistentKeepalive disabled for $pubkey!"
fi

# --- Phase 1: DDNS 漂移检测与热更新（IPv4） ---
current_endpoint=$($TIMEOUT_CMD wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
current_ip=$(extract_ip "$current_endpoint")

real_ip=$(resolve_ddns)

if [ -n "$real_ip" ] && ! is_public_ip "$real_ip"; then
    log "WARNING: DNS returned invalid/private IP ($real_ip). Ignoring."
    real_ip=""
fi

if [ -n "$real_ip" ] && [ "$current_ip" != "$real_ip" ]; then
    log "Phase 1: DDNS drift detected. Updating $current_ip -> $real_ip"
    if $TIMEOUT_CMD wg set "$WG_IF" peer "$pubkey" endpoint "${real_ip}:${ENDPOINT_PORT}"; then
        new_endpoint=$($TIMEOUT_CMD wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
        new_ip=$(extract_ip "$new_endpoint")
        if [ "$new_ip" = "$real_ip" ]; then
            # 主动 ping 触发一次握手，不干等对端 keepalive，避免验证窗口过短误判
            ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1
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

# --- Phase 3: 硬重启（本阶段失败才计入失败次数，避免 DDNS 持续漂移绕过断路器） ---
log "Phase 3: Hard restarting interface '$WG_IF'..."
$TIMEOUT_CMD ifdown "$WG_IF" || log "WARNING: Interface $WG_IF down failed."
sleep 3
$TIMEOUT_CMD ifup "$WG_IF" || log "ERROR: Interface $WG_IF restart failed."
sleep 15
# ifup 后主动 ping 一次再等，触发握手，避免验证窗口过短误判
ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1
sleep 3

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
