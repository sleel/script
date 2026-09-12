#!/bin/bash
# PVE 单节点一键优化脚本 v4（幂等，可重复执行）
# 适用: 低配单机 PVE，无集群、无 HA 资源
#
# 执行前确认: lvs 里存在 pve/swap 与 pve/data；ha-manager config 为空；系统盘是普通 SSD
# 注意: 第4步的 thin_pool_autoextend 依赖 VG 有空闲空间才能触发，
#       第6步会用 +100%FREE 把空闲空间几乎耗尽，两者是设计取舍不是 bug

set -uo pipefail

# 颜色（换成高对比度版本，暗色/亮色终端都能看清）
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
HEADER='\033[1;35m'
CYAN='\033[0;36m'
NC='\033[0m'

section() { echo -e "\n${HEADER}== $1 ==${NC}"; }
info()    { echo -e "${CYAN}[信息]${NC} $1"; }
ok()      { echo -e "${GREEN}[成功]${NC} $1"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $1"; }
err()     { echo -e "${RED}[错误]${NC} $1"; }

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }

if ! lvs /dev/pve/swap /dev/pve/data >/dev/null 2>&1; then
  err "未找到 pve/swap 或 pve/data, LV 命名不默认, 终止"
  exit 1
fi

if ha-manager config 2>/dev/null | grep -q .; then
  warn "检测到 HA 资源，跳过 pve-ha-lrm/pve-ha-crm 停用"
  SKIP_HA=1
else
  SKIP_HA=0
fi

section "1. 停用集群/HA/邮件服务"
if [ "$SKIP_HA" = 0 ]; then
  systemctl stop pve-ha-lrm pve-ha-crm 2>/dev/null || true
  systemctl mask pve-ha-lrm pve-ha-crm 2>/dev/null || true
  ok "已停用: pve-ha-lrm, pve-ha-crm"
fi
systemctl stop postfix corosync 2>/dev/null || true
systemctl mask postfix corosync 2>/dev/null || true
ok "已停用: postfix, corosync（watchdog-mux 未改动）"

section "2. journald 限容 100M"
if grep -Eq '^[#[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf; then
  sed -i -E 's|^[#[:space:]]*SystemMaxUse=.*|SystemMaxUse=100M|' /etc/systemd/journald.conf
else
  sed -i '/^\[Journal\]/a SystemMaxUse=100M' /etc/systemd/journald.conf
fi
systemctl restart systemd-journald
ok "$(grep '^SystemMaxUse=' /etc/systemd/journald.conf)"

section "3. sysctl: swappiness=10"
cat > /etc/sysctl.d/99-pve-io-tuning.conf << 'EOF'
vm.swappiness = 10
EOF
sysctl -p /etc/sysctl.d/99-pve-io-tuning.conf

section "4. lvm.conf: discard + thin pool 自动扩容"
sed -i -E 's|^[#[:space:]]*issue_discards[[:space:]]*=.*|\tissue_discards = 1|' /etc/lvm/lvm.conf
sed -i -E 's|^[#[:space:]]*thin_pool_autoextend_threshold[[:space:]]*=.*|\tthin_pool_autoextend_threshold = 80|' /etc/lvm/lvm.conf
sed -i -E 's|^[#[:space:]]*thin_pool_autoextend_percent[[:space:]]*=.*|\tthin_pool_autoextend_percent = 20|' /etc/lvm/lvm.conf

for key in issue_discards thin_pool_autoextend_threshold thin_pool_autoextend_percent; do
  cnt=$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" /etc/lvm/lvm.conf)
  if [ "$cnt" -gt 1 ]; then
    warn "${key} 重复 ${cnt} 次，自动去重"
    tmpfile=$(mktemp)
    awk -v key="$key" '
      $0 ~ "^[[:space:]]*(" key ")[[:space:]]*=" {
        if (seen) { print "#" $0; next }
        seen=1
      }
      { print }
    ' /etc/lvm/lvm.conf > "$tmpfile" && mv "$tmpfile" /etc/lvm/lvm.conf && chmod 644 /etc/lvm/lvm.conf
  fi
done

for key in issue_discards thin_pool_autoextend_threshold thin_pool_autoextend_percent; do
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" /etc/lvm/lvm.conf; then
    ok "$(grep -E "^[[:space:]]*${key}[[:space:]]*=" /etc/lvm/lvm.conf)"
  else
    err "${key} 未生效，请检查 /etc/lvm/lvm.conf"
  fi
done

systemctl enable --now lvm2-monitor 2>/dev/null || true
[ "$(systemctl is-active lvm2-monitor)" = "active" ] && ok "lvm2-monitor: active" || warn "lvm2-monitor 未激活，autoextend 可能不触发"

section "5. LXC 每周 trim"
cat > /usr/local/sbin/pct-fstrim-all.sh << 'EOF'
#!/bin/bash
for ct in $(pct list | awk 'NR>1 {print $1}'); do
  echo "[$(date '+%F %T')] CT $ct:"
  /usr/sbin/pct fstrim "$ct" 2>&1 || echo "  CT $ct trim 失败"
done
EOF
chmod +x /usr/local/sbin/pct-fstrim-all.sh
cat > /etc/cron.d/pct-fstrim-all << 'EOF'
30 2 * * 1 root /usr/local/sbin/pct-fstrim-all.sh >> /root/pct-fstrim.log 2>&1
EOF
ok "cron 已写入 (每周一 02:30，日志 /root/pct-fstrim.log)"

section "6. swap 缩容"
CURSWAP=$(lvs --noheadings --units g --nosuffix -o lv_size /dev/pve/swap | tr -d ' <')
info "当前 swap: ${CURSWAP}G"
if [ "${CURSWAP%%.*}" -le 1 ]; then
  ok "swap 已 <=1G，跳过"
elif [ ! -t 0 ]; then
  warn "非交互环境，跳过 swap 缩容"
else
  free -h; swapon --show
  read -rp "$(echo -e ${YELLOW}"缩小 swap 到 1G 并把空余并入 thin pool? (y/N) "${NC})" confirm
  if [[ "$confirm" =~ ^[yY]$ ]]; then
    swapoff /dev/pve/swap
    OLDUUID=$(blkid -s UUID -o value /dev/pve/swap)
    lvreduce --fs ignore -L 1G /dev/pve/swap
    NEWSZ=$(lvs --noheadings --units g --nosuffix -o lv_size /dev/pve/swap | tr -d ' <')
    if [ "${NEWSZ%%.*}" != "1" ]; then
      err "缩容异常 (当前 ${NEWSZ}G), 中止"; exit 1
    fi
    mkswap -U "$OLDUUID" /dev/pve/swap
    swapon -a && swapon --show
    ok "swap 已缩容至 1G"
    FREE=$(vgs --noheadings --units g --nosuffix -o vg_free pve | tr -d ' <')
    if [ "${FREE%%.*}" -ge 1 ]; then
      lvextend -l +100%FREE /dev/pve/data
      ok "空余空间已并入 local-lvm"
    else
      warn "VG 空闲不足 1G，跳过扩容"
    fi
  else
    info "已跳过 swap 缩容"
  fi
fi

section "完成: 状态核对"
for s in pve-ha-lrm pve-ha-crm postfix corosync watchdog-mux; do
  echo -e "${CYAN}$s${NC}: $(systemctl is-active $s 2>/dev/null) / $(systemctl is-enabled $s 2>/dev/null)"
done
grep '^SystemMaxUse=' /etc/systemd/journald.conf
sysctl vm.swappiness
swapon --show
lvs pve/data pve/swap -o lv_name,lv_size,data_percent
systemctl is-active lvm2-monitor
echo -e "${GREEN}建议: 跑一次 /usr/local/sbin/pct-fstrim-all.sh 做首次全量 trim${NC}"
