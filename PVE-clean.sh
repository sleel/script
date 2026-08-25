#!/usr/bin/env bash
# PVE-clean.sh — Proxmox VE 内核/系统清理脚本
# 用法: ./PVE-clean.sh [-e] [-k N] [-h] (不加 -e 为 dry-run)
set -euo pipefail

export LC_ALL=C
EXECUTE=false
KEEP_COUNT=1 # 保留最近内核版本数（当前运行内核始终额外保留），生产建议 2
JOURNAL_SIZE="100M"
JOURNAL_AGE_DAYS=3
BACKUP_ENABLE=false # 改成 true 即可开启回滚素材备份，无需命令行参数
: "${TEST_ROOT:=}" # 测试用根路径重定向，生产环境留空
LOG_FILE="${TEST_ROOT}/var/log/pve-clean.log"
BACKUP_ROOT="${TEST_ROOT}/root/pve-clean-backups"
BACKUP_KEEP=10
LOCK_DIR="${TEST_ROOT}/var/run"
LOCK_FILE="${LOCK_DIR}/pve-clean.lock"

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; NC="\033[0m"
green(){ printf "${GREEN}%s${NC}\n" "$*"; }
yellow(){ printf "${YELLOW}%s${NC}\n" "$*"; }
red(){ printf "${RED}%s${NC}\n" "$*"; }
action(){ green "[+] $*"; }
warn(){ yellow "[!] $*"; }
err(){ red "[x] $*"; }

usage(){
cat <<EOF
用法: $0 [-e] [-k N] [-h]
  -e     实际执行清理（不加此参数为 dry-run 预览）
  -k N   保留最近 N 个内核版本（当前运行内核始终额外保留），默认 ${KEEP_COUNT}
  -h     显示本帮助
EOF
exit 0
}

# 注：getopts 选项串必须是 "ek:h"（-k 后带冒号表示需要参数），否则 -k 拿不到
# OPTARG，KEEP_COUNT 会被置空并被下面的数字校验拦下。部署前建议执行一次
# grep getopts PVE-clean.sh 确认冒号存在，或直接跑 -k 2 观察是否报错。
while getopts "ek:h" opt; do
case "$opt" in
e) EXECUTE=true ;;
k) KEEP_COUNT="$OPTARG" ;;
h) usage ;;
*) usage ;;
esac
done

[[ "$KEEP_COUNT" =~ ^[0-9]+$ ]] || { err "-k 参数必须是正整数"; exit 1; }
[ "$EUID" -eq 0 ] || { err "本脚本需要 root 权限运行"; exit 1; }

# 并发锁：9>&- 关闭锁 fd，脚本被强杀也不留孤儿锁
LOCK_ACTIVE=false
if command -v flock >/dev/null 2>&1; then
mkdir -p "$LOCK_DIR" 2>/dev/null || true
exec 9>"$LOCK_FILE" 2>/dev/null || exec 9>/tmp/pve-clean.lock
if ! flock -n 9; then err "已有一个实例在运行 (锁: ${LOCK_FILE})"; exit 1; fi
LOCK_ACTIVE=true
else
warn "缺少 flock，跳过并发保护"
fi

mkdir -p "${TEST_ROOT}/var/log" "${TEST_ROOT}/root" "${TEST_ROOT}/tmp" 2>/dev/null || true
SIM="$(mktemp "${TEST_ROOT}/tmp/pve-clean.sim.XXXXXX" 2>/dev/null || mktemp /tmp/pve-clean.sim.XXXXXX)"
trap 'rm -f "$SIM"' EXIT

log(){ echo "$(date '+%F %T') $*" >>"$LOG_FILE" 2>/dev/null || true; }

# 只测目标目录大小，不测整盘，避免被无关磁盘活动(VM/容器写入等)污染出假数字
paths_size_kb(){
local total=0 p sz
for p in "$@"; do
[ -e "$p" ] || continue
sz="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
total=$(( total + ${sz:-0} ))
done
echo "$total"
}

human_kb(){
local kb="${1:-0}"
if command -v numfmt >/dev/null 2>&1; then
numfmt --to=iec --suffix=B --from-unit=1024 "$kb" 2>/dev/null || echo "${kb}KB"
else
echo "${kb}KB"
fi
}

TOTAL_FREED_KB=0
print_freed(){
local label="$1" before="${2:-0}" after="${3:-0}" freed
freed=$(( before - after )); [ "$freed" -lt 0 ] && freed=0
TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed ))
printf " %s: %8s\n" "$label" "$(human_kb "$freed")"
}

backup_rollback_materials(){
if ! $BACKUP_ENABLE; then action "回滚素材备份已跳过（BACKUP_ENABLE=false）"; return 0; fi
local ts backup_dir
ts="$(date '+%Y%m%d-%H%M%S')"; backup_dir="${BACKUP_ROOT}/${ts}"; mkdir -p "$backup_dir"
action "备份回滚素材到 ${backup_dir} ..."
dpkg --get-selections 9>&- > "${backup_dir}/dpkg-selections.list" 2>/dev/null || true
dpkg -l 9>&- | awk '$1=="ii"{print $2, $3}' | grep -E '^(pve-kernel|proxmox-kernel|pve-headers|proxmox-headers)-' \
> "${backup_dir}/kernel-pkgs-installed.list" 2>/dev/null || true
if command -v proxmox-boot-tool >/dev/null 2>&1; then
proxmox-boot-tool status 9>&- > "${backup_dir}/proxmox-boot-tool-status.txt" 2>&1 || true
else
echo "proxmox-boot-tool 未安装" > "${backup_dir}/proxmox-boot-tool-status.txt"
fi
uname -a 9>&- > "${backup_dir}/uname.txt"
ls -la "${TEST_ROOT}/boot" 9>&- > "${backup_dir}/boot-listing.txt" 2>/dev/null || true
[ -f "${TEST_ROOT}/etc/kernel/proxmox-boot-uuids" ] && cp "${TEST_ROOT}/etc/kernel/proxmox-boot-uuids" "${backup_dir}/" || true
[ -f "${TEST_ROOT}/etc/kernel/pin" ] && cp "${TEST_ROOT}/etc/kernel/pin" "${backup_dir}/" || true
[ "${#REMOVE_PKGS[@]}" -gt 0 ] && printf '%s\n' "${REMOVE_PKGS[@]}" > "${backup_dir}/planned-remove.list"
printf '%s\n' "${KEEP_VERSIONS[@]:-}" > "${backup_dir}/keep-versions.list"
log "backup written to ${backup_dir}"
mapfile -t OLD_BACKUPS < <({ ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))"; } 9>&-)
for d in "${OLD_BACKUPS[@]:-}"; do [[ -z "$d" ]] && continue; rm -rf -- "$d"; log "removed old backup: $d"; done
}

# 内核版本探测：当前运行内核永远保留，-k 只影响额外保留的历史版本数
CURRENT_UNAME="$(uname -r)"
CURRENT_VER="$(echo "$CURRENT_UNAME" | sed -E 's/-signed$//')"
normalize_ver(){ local v="$1"; v="${v#pve-kernel-}"; v="${v#proxmox-kernel-}"; v="${v%-signed}"; echo "$v"; }
extract_meta_ver(){ echo "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true; }
is_meta_match(){ [[ "$1" == "$2"* ]]; }

mapfile -t ALL_PKGS < <({ dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -E '^(pve-kernel|proxmox-kernel)-' || true; } 9>&-)
mapfile -t META_PKGS < <(printf '%s\n' "${ALL_PKGS[@]:-}" | grep -E '^(pve-kernel|proxmox-kernel)-[0-9]+\.[0-9]+$' || true)
mapfile -t REAL_PKGS < <(printf '%s\n' "${ALL_PKGS[@]:-}" | grep -E '^(pve-kernel|proxmox-kernel)-[0-9]+\.[0-9]+\.[0-9]+' || true)

# 头文件包(pve-headers-*/proxmox-headers-*)单独收集：旧内核实体清理后 headers 若不主动
# 匹配清理，只能靠后续 autoremove 顺带处理，可能残留孤立的旧版本 headers
mapfile -t HEADER_PKGS < <({ dpkg -l 2>/dev/null | awk '$1=="ii"{print $2}' | grep -E '^(pve-headers|proxmox-headers)-[0-9]' || true; } 9>&-)

action "检测到内核实体包: ${#REAL_PKGS[@]} 个"
action "检测到内核 Meta 包: ${#META_PKGS[@]} 个"
action "检测到内核 Headers 包: ${#HEADER_PKGS[@]} 个"

declare -A PKGS_BY_VER
VERSIONS=()
for pkg in "${REAL_PKGS[@]:-}"; do
[[ -z "$pkg" ]] && continue
ver="$(normalize_ver "$pkg")"
PKGS_BY_VER["$ver"]="${PKGS_BY_VER[$ver]:-} $pkg"
VERSIONS+=("$ver")
done

mapfile -t SORTED < <(printf '%s\n' "${VERSIONS[@]:-}" | awk '!seen[$0]++ && $0!=""' | sort -V -r)
KEEP_VERSIONS=("${SORTED[@]:0:KEEP_COUNT}")
if ! printf '%s\n' "${KEEP_VERSIONS[@]:-}" | grep -qx "$CURRENT_VER"; then KEEP_VERSIONS+=("$CURRENT_VER"); fi
mapfile -t KEEP_VERSIONS < <(printf '%s\n' "${KEEP_VERSIONS[@]:-}" | awk '!seen[$0]++ && $0!=""')

echo; action "将保留的内核版本:"; printf ' %s\n' "${KEEP_VERSIONS[@]}"

KEEP_PKGS=()
for v in "${KEEP_VERSIONS[@]}"; do KEEP_PKGS+=(${PKGS_BY_VER[$v]:-}); done

REMOVE_PKGS=()
for p in "${REAL_PKGS[@]:-}"; do
[[ -z "$p" ]] && continue
keep=false
for kp in "${KEEP_PKGS[@]:-}"; do [[ "$p" == "$kp" ]] && { keep=true; break; }; done
$keep || REMOVE_PKGS+=("$p")
done
for meta in "${META_PKGS[@]:-}"; do
[[ -z "$meta" ]] && continue
mver="$(extract_meta_ver "$meta")"
keep=false
for v in "${KEEP_VERSIONS[@]}"; do is_meta_match "$v" "$mver" && { keep=true; break; }; done
$keep || REMOVE_PKGS+=("$meta")
done
# headers 包按同样的版本号匹配逻辑纳入删除计划，避免旧版本 headers 残留
for hp in "${HEADER_PKGS[@]:-}"; do
[[ -z "$hp" ]] && continue
hver="$(echo "$hp" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?(-pve)?' | head -n1 || true)"
[[ -z "$hver" ]] && continue
keep=false
for v in "${KEEP_VERSIONS[@]}"; do [[ "$hver" == "$v"* || "$v" == "$hver"* ]] && { keep=true; break; }; done
$keep || REMOVE_PKGS+=("$hp")
done

echo
if [ "${#REMOVE_PKGS[@]}" -eq 0 ]; then action "无需删除的内核/Meta/Headers 包"
else action "计划删除以下 ${#REMOVE_PKGS[@]} 个包:"; printf ' %s\n' "${REMOVE_PKGS[@]}"; fi

if ! $EXECUTE; then echo; warn "当前为 DRY-RUN 模式，未执行任何更改。加 -e 参数以实际执行。"; exit 0; fi

backup_rollback_materials

KERNEL_BEFORE="$(paths_size_kb "${TEST_ROOT}/boot" "${TEST_ROOT}/lib/modules")"

# 内核 purge：先模拟(-s)校验依赖安全，再真正执行
if [ "${#REMOVE_PKGS[@]}" -gt 0 ]; then
action "执行 apt-get update..."
apt-get update -y >/dev/null 2>&1 9>&- || warn "apt-get update 失败，继续尝试模拟检查"
set +e
apt-get -s purge "${REMOVE_PKGS[@]}" >"$SIM" 2>&1 9>&-
CODE=$?
set -e
if [ "$CODE" -ne 0 ]; then err "模拟失败，退出前打印详情（临时文件将被清理）："; cat "$SIM"; exit 1; fi
if grep -Ei "NEW packages will be installed" "$SIM"; then
err "模拟显示将安装新包（可能是依赖错误的 unsigned 内核），操作已取消！"; exit 1
fi
action "模拟检查通过，开始执行内核 purge..."
if apt-get purge -y "${REMOVE_PKGS[@]}" 9>&-; then log "purged: ${REMOVE_PKGS[*]}"
else err "内核 purge 失败"; exit 1; fi
else
action "无需删除旧内核"
fi

KERNEL_AFTER="$(paths_size_kb "${TEST_ROOT}/boot" "${TEST_ROOT}/lib/modules")"

echo; action "开始执行系统深度清理..."
action "执行 apt autoremove..."
apt-get autoremove -y --purge 9>&- || warn "autoremove 未完全成功"

CACHE_BEFORE="$(paths_size_kb "${TEST_ROOT}/var/cache/apt")"
action "执行 apt autoclean (Round 1)..."
apt-get autoclean -y 9>&- || true
apt-get clean -y 9>&- || true

mapfile -t RC_PKGS < <({ dpkg -l | awk '$1=="rc"{print $2}'; } 9>&-)
if [ "${#RC_PKGS[@]}" -gt 0 ]; then
action "发现并清除 dpkg 残留配置 (${#RC_PKGS[@]} 个)..."
apt-get purge -y "${RC_PKGS[@]}" 9>&- || warn "部分残留配置清除失败"
else
action "无 dpkg 残留配置"
fi

# 引导同步：grub 始终尝试；proxmox-boot-tool 只有已初始化(存在 uuids 记录)才调用
if command -v update-grub >/dev/null 2>&1; then
action "更新 Grub 引导..."
update-grub 9>&- || err "Grub 更新失败！请手动检查"
fi
if command -v proxmox-boot-tool >/dev/null 2>&1 && [ -f "${TEST_ROOT}/etc/kernel/proxmox-boot-uuids" ]; then
action "同步 ESP 引导分区 (proxmox-boot-tool refresh)..."
proxmox-boot-tool refresh 9>&- || err "proxmox-boot-tool refresh 失败！请手动检查"
else
action "未检测到 proxmox-boot-tool 初始化记录，跳过 ESP 同步（本机为纯 grub 引导）"
log "skip proxmox-boot-tool refresh"
fi

LOG_BEFORE="$(paths_size_kb "${TEST_ROOT}/var/log")"
action "清理 systemd journal (上限 ${JOURNAL_SIZE}，保留 ${JOURNAL_AGE_DAYS} 天)..."
journalctl --vacuum-size="$JOURNAL_SIZE" 9>&- || true
journalctl --vacuum-time="${JOURNAL_AGE_DAYS}d" 9>&- || true

action "清理 /var/log 中超过 ${JOURNAL_AGE_DAYS} 天的轮替日志..."
find "${TEST_ROOT}/var/log" -type f -regextype posix-extended -regex '.*\.[0-9]+(\.gz)?$' -mtime +"${JOURNAL_AGE_DAYS}" -delete 2>/dev/null || true
# 注：/var/log/journal 已由上面的 journalctl --vacuum-* 处理，不再用 find -delete 直接
# 操作该目录下的二进制日志文件，避免绕过 journald 自身的文件管理造成索引不一致
if [ -d "${TEST_ROOT}/var/log.save" ]; then
find "${TEST_ROOT}/var/log.save" -type f -regextype posix-extended -regex '.*\.[0-9]+(\.gz)?$' -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
fi
[ -d "${TEST_ROOT}/var/cache/e2fsck" ] && find "${TEST_ROOT}/var/cache/e2fsck" -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
[ -d "${TEST_ROOT}/var/lib/clamav" ] && find "${TEST_ROOT}/var/lib/clamav" -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
LOG_AFTER="$(paths_size_kb "${TEST_ROOT}/var/log")"

if [ -d "${TEST_ROOT}/var/cache/apt/archives" ]; then
action "执行 apt autoclean (Round 2)..."
apt-get autoclean -y 9>&- || true
fi
CACHE_AFTER="$(paths_size_kb "${TEST_ROOT}/var/cache/apt")"

# 废弃内核模块清理：删除不在保留名单里的 /lib/modules/<版本> 目录
MODULE_BEFORE="$(paths_size_kb "${TEST_ROOT}/lib/modules")"
MODDIR="${TEST_ROOT}/lib/modules"
if [ -d "$MODDIR" ]; then
action "检查废弃的内核模块目录..."
ALLOWED=()
for v in "${KEEP_VERSIONS[@]}"; do
ALLOWED+=("$v")
if [[ "$v" == *"-pve" ]]; then ALLOWED+=("${v%-pve}"); else ALLOWED+=("${v}-pve"); fi
done
ALLOWED+=("$CURRENT_UNAME")
mapfile -t DIRS < <({ ls -1 "$MODDIR" 2>/dev/null || true; } 9>&-)
for d in "${DIRS[@]:-}"; do
[[ -z "$d" ]] && continue
if ! printf '%s\n' "${ALLOWED[@]}" | grep -qx "$d"; then
# 兜底：若 /boot 里仍有对应的 vmlinuz 镜像，说明这可能是自行编译/手动安装的
# 内核（不受 pve-kernel 包管理），模块目录不该被删——否则内核镜像还在但
# 模块没了，grub 里会留一个实际启动不了的条目。
if [ -e "${TEST_ROOT}/boot/vmlinuz-$d" ]; then
warn "跳过 $d：/boot 中仍有对应 vmlinuz，可能是非 pve-kernel 包管理的内核"
continue
fi
action "删除废弃模块目录: $d"
rm -rf --one-file-system "${MODDIR:?}/${d:?}"
log "removed module dir: $MODDIR/$d"
fi
done
fi
MODULE_AFTER="$(paths_size_kb "${TEST_ROOT}/lib/modules")"

echo
action "===== 空间释放汇总 ====="
print_freed "内核清理" "$KERNEL_BEFORE" "$KERNEL_AFTER"
print_freed "缓存清理" "$CACHE_BEFORE" "$CACHE_AFTER"
print_freed "日志清理" "$LOG_BEFORE" "$LOG_AFTER"
print_freed "模块清理" "$MODULE_BEFORE" "$MODULE_AFTER"
action "总计释放: $(human_kb "$TOTAL_FREED_KB")"

echo; action "清理任务完成"
df -h / || true
