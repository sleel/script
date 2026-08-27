#!/bin/sh
# WireGuard Watchdog for OpenWrt v2.4.1 (IPv6-only)
# 状态机 + 断路器：DDNS漂移热更新 -> ping唤醒NAT -> 硬重启，失败达阈值后静默保护
# 用途：主服务器切换到 IPv6 时使用（例如运营商封锁 IPv4 时的备用方案）

export PATH=/sbin:/bin:/usr/sbin:/usr/bin

WG_IF="wg0"
THRESHOLD=300          # 无握手超过此秒数视为异常
PING_HOST="10.0.198.1" # 对端隧道内网地址（隧道内部地址，与端点IP族无关）

# !!! 必须替换为真实值，否则启动即拒绝运行 !!!
DDNS_DOMAIN="cctv.com"
ENDPOINT_PORT="8888888"  # 1-65535

# DDNS 解析链：nslookup 直连，绕开系统/本地缓存
# 可直接改写死的 AAAA 地址，如 kai.ns.cloudflare.com = 2606:4700:58::adf5:3bbc（实测）
AUTH_NS1="kai.ns.cloudflare.com"
AUTH_NS2="rihana.ns.cloudflare.com"
DNS_SERVERS="2606:4700:4700::1111 2400:3200::1 2001:4860:4860::8888" # IPv6 公共递归，空格分隔

SKIP_AFTER_ACTION=240  # 动作后冷却期(秒)
MAX_FAILURES=10        # 触发静默保护前允许的最大连续失败次数
SILENCE_DURATION=3600  # 静默保护时长(秒)
CMD_TIMEOUT=8          # 外部命令超时保护(秒)
LOCK_MAX_AGE=240       # 锁目录最大存活时长(秒)，需覆盖最坏运行时长(约100s)

# 与 v4 版共用同一把锁：防止两版同时启用时并发 ifdown/ifup 互踩
LOCKDIR="/tmp/wg-watchdog-${WG_IF}.lock"
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

# 从 endpoint 提取纯 IP：兼容 [v6]:port 与 v4:port（后者仅兜底，正常不会出现）
extract_ip() {
  case "$1" in
    \[*\]:*) echo "$1" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/' ;;
    *.*.*.*:*) echo "$1" | sed -E 's/:[0-9]+$//' ;;
    *) echo "$1" ;;
  esac
}

# IPv6 公网合法性校验：字符集 + 结构(段数/段长/压缩位置) + 排除非公网段
is_public_ip() {
  local ip
  ip=$(echo "$1" | tr 'A-F' 'a-f')
  case "$ip" in
    *[!0-9a-f:]*) return 1 ;;
    *:*) : ;;
    *) return 1 ;;
  esac
  case "$ip" in
    *:::*) return 1 ;; # 三连冒号非法
    *::*::*) return 1 ;; # 至多一个 ::
    ::*|*::) : ;; # :: 开头/结尾合法
    :*|*:) return 1 ;; # 单冒号开头/结尾非法
  esac
  echo "$ip" | awk -F: 'NF>8 {exit 1} {for(i=1;i<=NF;i++) if(length($i)>4) exit 1}' || return 1
  case "$ip" in
    *::*) : ;;
    *) echo "$ip" | awk -F: 'NF==8 && $1!="" && $NF!="" {ok=1} END{exit !ok}' || return 1 ;;
  esac
  case "$ip" in
    ::|::1) return 1 ;; # 未指定/回环
    fe8*|fe9*|fea*|feb*) return 1 ;; # 链路本地 fe80::/10
    fc*|fd*) return 1 ;; # ULA fc00::/7
    ff*) return 1 ;; # 组播 ff00::/8
    2001:db8:*|2001:db8) return 1 ;; # 文档前缀 2001:db8::/32
    2001::*|2001:0:*|2001:0::*|2001:0) return 1 ;; # Teredo 2001::/32
    2002:*) return 1 ;; # 6to4 2002::/16
    ::ffff:*) return 1 ;; # IPv4-mapped
    100::*|100:0::*|100:0:0:0::*) return 1 ;; # discard-only 100::/64
    *) return 0 ;;
  esac
}

# 解析 DDNS(AAAA)：nslookup 直连（$DNS_SERVERS 故意不加引号做分词）
# awk 只取 "Name:" 之后的 Address 行且必须含冒号，避免误食服务器自身地址或 A 记录
resolve_ddns() {
  local ip="" server=""
  for server in "$AUTH_NS1" "$AUTH_NS2" $DNS_SERVERS; do
    [ -z "$server" ] && continue
    ip=$($TIMEOUT_CMD nslookup "$DDNS_DOMAIN" "$server" 2>/dev/null \
      | awk '/^Name:/{f=1} f && /^Address/ {print $NF}' \
      | grep ':' | tail -n1)
    [ -n "$ip" ] && break
  done
  echo "$ip"
}

# 读锁目录 mtime 算锁龄（写入全局 lock_mtime / lock_age）
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

# 启动校验
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
if [ -z "$AUTH_NS1" ] && [ -z "$AUTH_NS2" ] && [ -z "$DNS_SERVERS" ]; then
  log "CONFIG ERROR: 解析链全空（AUTH_NS1/AUTH_NS2/DNS_SERVERS 至少配一个）。Exit."
  exit 1
fi
# DNS_SERVERS 逐成员须为公网 IPv6（权威 NS 允许主机名，不校验）
for srv in $DNS_SERVERS; do
  if ! is_public_ip "$srv"; then
    log "CONFIG ERROR: DNS_SERVERS 成员 ($srv) 须为公网 IPv6。Exit."
    exit 1
  fi
done
unset srv

# 并发锁：陈旧锁自愈（pid 存活 + 锁龄双条件判定）
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

# 属主确认 + trap 带属主校验，防并发实例误删锁
sleep 1
[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] || exit 0
trap '[ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKDIR"' EXIT

# 接口可用性检查：先自愈一次
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

# 遍历全部 peer 取最陈旧握手，多 peer 不漏检
all_peers=$($TIMEOUT_CMD wg show "$WG_IF" latest-handshakes 2>/dev/null)
if [ -z "$all_peers" ]; then
  log "No peer found on '$WG_IF'. Exit."
  exit 0
fi

pubkey=""
latest_handshake=0
age=-1
worst_age=-1

while read -r p h; do
  [ -z "$p" ] && continue
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  if [ "$h" -eq 0 ]; then
    a=$((THRESHOLD + 1))
  elif [ "$h" -gt "$now" ]; then
    a=0 # NTP 回拨，保守认定为刚握手过
  else
    a=$((now - h))
  fi
  if [ "$a" -gt "$worst_age" ]; then
    worst_age="$a"
    pubkey="$p"
    latest_handshake="$h"
    age="$a"
  fi
done <<EOF
$all_peers
EOF

if [ "$age" -le "$THRESHOLD" ]; then
  clear_fail_state
  exit 0
fi

# === 异常恢复流程 ===

# 断路器：静默期内跳过全部恢复动作
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

# 前置步骤可能已耗时数秒，刷新时间基准
now=$(date +%s)

log "Peer $pubkey stale (age=${age}s). Initiating recovery..."

keepalive=$($TIMEOUT_CMD wg show "$WG_IF" persistent-keepalive 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
if [ -z "$keepalive" ] || [ "$keepalive" = "off" ]; then
  log "WARNING: PersistentKeepalive disabled for $pubkey!"
fi

# --- Phase 1: DDNS 漂移检测与热更新（IPv6，权威 DNS 直连，结果即真值） ---
current_endpoint=$($TIMEOUT_CMD wg show "$WG_IF" endpoints 2>/dev/null | awk -v key="$pubkey" '$1==key {print $2}')
current_ip=$(extract_ip "$current_endpoint")

real_ip=$(resolve_ddns)

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
      ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 # 主动触发握手
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

# --- Phase 3: 硬重启（仅此阶段失败计入失败次数） ---
log "Phase 3: Hard restarting interface '$WG_IF'..."
killall -HUP dnsmasq 2>/dev/null # ifup 会走系统解析重设 endpoint，先清缓存防陈旧记录
$TIMEOUT_CMD ifdown "$WG_IF" || log "WARNING: Interface $WG_IF down failed."
sleep 3
$TIMEOUT_CMD ifup "$WG_IF" || log "ERROR: Interface $WG_IF restart failed."
sleep 15

ping -c 1 -W 3 "$PING_HOST" >/dev/null 2>&1 # 触发握手
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
