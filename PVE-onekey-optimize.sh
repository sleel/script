#!/bin/bash
# PVE 单节点一键优化脚本 v5（最终版）
# 适用: 低配单机 PVE（Debian 12/13, PVE 8/9），无集群、无 HA
# 用法: bash PVE-onekey-optimize-final.sh [--dry-run]
# 设计: 幂等可重跑；改动前自动备份 .bak（保留首版）；失败尽量回滚

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'
HEADER='\033[1;35m'; CYAN='\033[0;36m'; NC='\033[0m'
section() { echo -e "\n${HEADER}== $1 ==${NC}"; }
info() { echo -e "${CYAN}[信息]${NC} $1"; }
ok()   { echo -e "${GREEN}[成功]${NC} $1"; }
warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
err()  { echo -e "${RED}[错误]${NC} $1"; }

run() {
    if [ $DRY_RUN = 1 ]; then echo -e "${YELLOW}[DRY]${NC} $*"; return 0; fi
    "$@"
}

backup() {
    local f
    for f in "$@"; do
        [ -e "${f}.bak" ] || run cp -a "$f" "${f}.bak"
    done
}

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
[ $DRY_RUN = 1 ] && warn "DRY-RUN 模式：只打印，不改动系统"

. /etc/os-release 2>/dev/null || true
if [ "${ID:-}" != "debian" ]; then
    err "当前系统 ID=${ID:-unknown}，本脚本仅面向 Debian 系 PVE，终止"
    exit 1
fi

if ! command -v pct >/dev/null 2>&1 && [ ! -d /etc/pve ]; then
    err "未检测到 PVE 环境（无 pct 且无 /etc/pve），终止"
    exit 1
fi

if ! lvs /dev/pve/swap /dev/pve/data >/dev/null 2>&1; then
    err "未找到 pve/swap 或 pve/data（LV 命名非默认），终止"
    exit 1
fi

if ha-manager config 2>/dev/null | grep -q .; then
    warn "检测到 HA 资源，跳过停用 pve-ha-lrm/pve-ha-crm"
    SKIP_HA=1
else
    SKIP_HA=0
fi

section "1. 停用集群/HA/邮件服务"
if [ $SKIP_HA = 0 ]; then
    run systemctl stop pve-ha-lrm pve-ha-crm 2>/dev/null || true
    run systemctl mask pve-ha-lrm pve-ha-crm 2>/dev/null || true
    ok "已停用: pve-ha-lrm, pve-ha-crm"
fi
run systemctl stop postfix corosync 2>/dev/null || true
run systemctl mask postfix corosync 2>/dev/null || true
ok "已停用: postfix, corosync（watchdog-mux 不动）"

section "2. journald 限容 100M"
JC=/etc/systemd/journald.conf
backup "$JC"
if grep -Eq '^[#[:space:]]*SystemMaxUse=' "$JC"; then
    run sed -i -E 's|^[#[:space:]]*SystemMaxUse=.*|SystemMaxUse=100M|' "$JC"
elif grep -q '^\[Journal\]' "$JC"; then
    run sed -i '/^\[Journal\]/a SystemMaxUse=100M' "$JC"
elif [ $DRY_RUN = 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} 追加 [Journal]/SystemMaxUse=100M 到 $JC"
else
    printf '\n[Journal]\nSystemMaxUse=100M\n' >> "$JC"
fi
run systemctl restart systemd-journald || warn "journald 重启失败"
if grep -q '^SystemMaxUse=100M' "$JC"; then
    ok "journald: SystemMaxUse=100M"
else
    err "SystemMaxUse 未写入 $JC"
fi

section "3. sysctl: swappiness=10"
SF=/etc/sysctl.d/99-pve-io-tuning.conf
if [ $DRY_RUN = 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} 写入 vm.swappiness = 10 -> $SF"
else
    printf 'vm.swappiness = 10\n' > "$SF"
    sysctl -p "$SF"
fi

section "4. lvm.conf: discard + thin pool 自动扩容"
LC=/etc/lvm/lvm.conf
backup "$LC"
run sed -i -E 's|^[#[:space:]]*issue_discards[[:space:]]*=.*|\tissue_discards = 1|' "$LC"
run sed -i -E 's|^[#[:space:]]*thin_pool_autoextend_threshold[[:space:]]*=.*|\tthin_pool_autoextend_threshold = 80|' "$LC"
run sed -i -E 's|^[#[:space:]]*thin_pool_autoextend_percent[[:space:]]*=.*|\tthin_pool_autoextend_percent = 20|' "$LC"

for key in issue_discards thin_pool_autoextend_threshold thin_pool_autoextend_percent; do
    cnt=$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" "$LC")
    if [ "$cnt" -gt 1 ]; then
        warn "$key 出现 $cnt 次，去重（保留第一条，其余注释）"
        tmp=$(mktemp /etc/lvm/.lvm.conf.XXXXXX) || { err "mktemp 失败"; exit 1; }
        awk -v k="$key" '
            $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (seen) { print "#" $0; next } seen=1 }
            { print }
        ' "$LC" > "$tmp"
        if [ $DRY_RUN = 1 ]; then
            rm -f "$tmp"
        else
            chmod 644 "$tmp" && mv "$tmp" "$LC"
        fi
    fi
done

for key in issue_discards thin_pool_autoextend_threshold thin_pool_autoextend_percent; do
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$LC" | head -1)
    if [ -n "$line" ]; then
        ok "$line"
    else
        err "$key 未写入 $LC（lvm.conf 缺该键，需手动添加到 global 段）"
    fi
done

run systemctl enable --now lvm2-monitor 2>/dev/null || true
[ "$(systemctl is-active lvm2-monitor)" = "active" ] \
    && ok "lvm2-monitor: active" \
    || warn "lvm2-monitor 未激活，autoextend 可能不触发"

section "5. LXC 每周 trim"
TS=/usr/local/sbin/pct-fstrim-all.sh
CF=/etc/cron.d/pct-fstrim-all
if [ $DRY_RUN = 1 ]; then
    echo -e "${YELLOW}[DRY]${NC} 重写 $TS（绝对路径+flock+仅 running 容器）与 $CF"
else
    cat > "$TS" << 'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/run/pct-fstrim.lock
flock -n 9 || { echo "[$(date '+%F %T')] 上一实例未结束，本次跳过"; exit 0; }
/usr/sbin/pct list | awk 'NR>1 && $2=="running" {print $1}' | while read -r ct; do
    echo "[$(date '+%F %T')] CT $ct:"
    /usr/sbin/pct fstrim "$ct" 2>&1 || echo "  CT $ct trim 失败"
done
EOF
    chmod 755 "$TS"
    cat > "$CF" << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
30 2 * * 1 root /usr/local/sbin/pct-fstrim-all.sh >> /root/pct-fstrim.log 2>&1
EOF
    chmod 644 "$CF"
fi
ok "cron: 每周一 02:30 -> /root/pct-fstrim.log"

section "6. swap 缩容（1G，空余并入 data）"
CURSWAP=$(lvs --noheadings --units g --nosuffix -o lv_size /dev/pve/swap | tr -d ' <')
info "当前 swap: ${CURSWAP}G"
SKIP_SWAP=0
if [ "${CURSWAP%%.*}" -le 1 ]; then
    ok "swap 已 <=1G，跳过"
    SKIP_SWAP=1
fi
if [ $SKIP_SWAP = 0 ] && ! [ -t 0 ]; then
    warn "stdin 非终端（curl|bash 场景），尝试接管 /dev/tty"
    exec </dev/tty 2>/dev/null || { warn "无法获得终端，跳过 swap 缩容"; SKIP_SWAP=1; }
fi
if [ $SKIP_SWAP = 0 ]; then
    free -h; swapon --show
    read -rp "$(echo -e "${YELLOW}缩小 swap 到 1G 并把空余并入 data? (y/N) ${NC}")" confirm
    if [[ "${confirm:-}" =~ ^[yY]$ ]]; then
        if [ $DRY_RUN = 1 ]; then
            echo -e "${YELLOW}[DRY]${NC} swapoff -> lvreduce 1G -> mkswap(保UUID) -> swapon -> lvextend data +100%FREE"
        else
            trap 'warn "脚本异常退出，尝试恢复 swap"; swapon /dev/pve/swap 2>/dev/null' EXIT
            swapoff /dev/pve/swap
            OLDUUID=$(blkid -s UUID -o value /dev/pve/swap)
            if ! lvreduce --fs ignore -L 1G /dev/pve/swap; then
                err "lvreduce 失败，正在恢复 swap"
                swapon /dev/pve/swap || err "swap 恢复失败，请立即手动执行: swapon -a"
                trap - EXIT
                exit 1
            fi
            NEWSZ=$(lvs --noheadings --units g --nosuffix -o lv_size /dev/pve/swap | tr -d ' <')
            if [ "${NEWSZ%%.*}" != "1" ]; then
                err "缩容结果异常（${NEWSZ}G），尝试还原"
                lvextend -l +100%FREE /dev/pve/swap 2>/dev/null || true
                mkswap -U "$OLDUUID" /dev/pve/swap >/dev/null 2>&1 || true
                swapon /dev/pve/swap 2>/dev/null || true
                trap - EXIT
                exit 1
            fi
            mkswap -U "$OLDUUID" /dev/pve/swap >/dev/null
            swapon -a
            SWDEV=$(readlink -f /dev/pve/swap)
            swapon --show=NAME --noheadings | grep -qx "$SWDEV" || { err "swapon 未生效，请检查"; exit 1; }
            trap - EXIT
            ok "swap 已缩容至 1G（UUID 保留: $OLDUUID）"
            FREE=$(vgs --noheadings --units g --nosuffix -o vg_free pve | tr -d ' <')
            if awk -v f="$FREE" 'BEGIN{exit !(f>=1)}'; then
                lvextend -l +100%FREE /dev/pve/data
                ok "空余空间已并入 local-lvm"
            else
                info "VG 空闲 ${FREE}G，不足 1G，跳过扩容"
            fi
        fi
    else
        info "已跳过 swap 缩容"
    fi
fi

section "完成: 状态核对"
for s in pve-ha-lrm pve-ha-crm postfix corosync watchdog-mux; do
    echo -e "${CYAN}$s${NC}: $(systemctl is-active $s 2>/dev/null) / $(systemctl is-enabled $s 2>/dev/null)"
done
grep '^SystemMaxUse=' "$JC" 2>/dev/null
sysctl vm.swappiness 2>/dev/null
swapon --show
lvs pve/data pve/swap -o lv_name,lv_size,data_percent 2>/dev/null
systemctl is-active lvm2-monitor 2>/dev/null
[ $DRY_RUN = 1 ] && warn "以上为 dry-run，未做任何改动"
echo -e "${GREEN}建议: 执行 env -i /bin/bash $TS 模拟 cron 环境验证 trim 脚本${NC}"
