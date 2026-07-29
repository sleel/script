#!/usr/bin/env bash
set -euo pipefail

# ------------- 配置参数 -------------
export LC_ALL=C
EXECUTE=false
KEEP_COUNT=1          # 保留最近内核的数量
JOURNAL_SIZE="100M"   # Systemd 日志大小限制
JOURNAL_AGE_DAYS=3    # 日志保留天数
GREEN="\033[32m"
NC="\033[0m"

green(){ printf "${GREEN}%s${NC}\n" "$*"; }
info(){ green "[-] $*"; }
action(){ green "[+] $*"; }

usage(){
cat <<EOF
Usage: $0 [-e] [-k N]
  -e    execute (默认 dry-run，仅预览)
  -k N  保留最新 N 个实际内核版本 (默认 1)
EOF
exit 0
}

while getopts "ek:h" opt; do
  case $opt in
    e) EXECUTE=true ;;
    k) KEEP_COUNT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ "$KEEP_COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "-k 必须为正整数"; exit 1; }
[ "$EUID" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

CURRENT_UNAME="$(uname -r)"
# 使用 sed 去除后缀，以增强对未来版本号格式的兼容性 (如 -cloud, -dbg)
CURRENT_VER="$(echo "$CURRENT_UNAME" | sed -E 's/-signed$//')"

# ---------- 内核版本识别逻辑 ----------

normalize_ver(){
  local p="$1"
  p="${p#pve-kernel-}"
  p="${p#proxmox-kernel-}"
  p="${p%-signed}"
  echo "$p"
}

extract_meta_ver(){
  echo "$1" | grep -oE '[0-9]+\.[0-9]+' || true
}

is_meta_match(){
  local v="$1"      # like 6.17.2-2-pve
  local m="$2"      # like 6.17
  [[ "$v" =~ ^${m}(\.|$) ]]
}

# 收集已安装的内核包
mapfile -t ALL_PKGS < <(dpkg -l | awk '/^ii/ && ($2 ~ /(pve-kernel|proxmox-kernel)-/) {print $2}')

mapfile -t META_PKGS < <(
  printf "%s\n" "${ALL_PKGS[@]}" | grep -E '^(pve|proxmox)-kernel-[0-9]+\.[0-9]+$' || true
)

mapfile -t REAL_PKGS < <(
  printf "%s\n" "${ALL_PKGS[@]}" | grep -E '(pve|proxmox)-kernel-[0-9]+\.[0-9]+\.[0-9]+' || true
)

action "实际内核包数量: ${#REAL_PKGS[@]}"
action "Meta 包数量     : ${#META_PKGS[@]}"

# 建立保留列表
declare -A PKGS_BY_VER
VERSIONS=()

for pkg in "${REAL_PKGS[@]}"; do
  ver="$(normalize_ver "$pkg")"
  PKGS_BY_VER["$ver"]+="$pkg "
  VERSIONS+=("$ver")
done

mapfile -t SORTED < <(printf "%s\n" "${VERSIONS[@]}" | awk '!seen[$0]++' | sort -V -r)

KEEP_VERSIONS=("${SORTED[@]:0:$KEEP_COUNT}")

# 确保当前内核不被删除
if ! printf "%s\n" "${KEEP_VERSIONS[@]}" | grep -qx "$CURRENT_VER"; then
  KEEP_VERSIONS+=("$CURRENT_VER")
fi

mapfile -t KEEP_VERSIONS < <(printf "%s\n" "${KEEP_VERSIONS[@]}" | awk '!seen[$0]++')

# 构建删除列表
KEEP_PKGS=()
for v in "${KEEP_VERSIONS[@]}"; do
  KEEP_PKGS+=(${PKGS_BY_VER[$v]:-})
done

REMOVE_PKGS=()
for p in "${REAL_PKGS[@]}"; do
  [[ " ${KEEP_PKGS[*]} " =~ " $p " ]] || REMOVE_PKGS+=("$p")
done

# Meta 包删除逻辑
REMOVE_META=()
for meta in "${META_PKGS[@]}"; do
  mver="$(extract_meta_ver "$meta")"
  keep=false
  for v in "${KEEP_VERSIONS[@]}"; do
    if is_meta_match "$v" "$mver"; then
      keep=true
      break
    fi
  done
  $keep || REMOVE_META+=("$meta")
done

REMOVE_PKGS=( "${REMOVE_META[@]}" "${REMOVE_PKGS[@]}" )

# ---------- 预览与模拟 ----------

echo
action "保留版本:"
printf "   %s\n" "${KEEP_VERSIONS[@]}"

echo
action "计划删除的内核包 (含 Meta):"
if [ ${#REMOVE_PKGS[@]} -eq 0 ]; then
  echo "   (无)"
else
  printf "   %s\n" "${REMOVE_PKGS[@]}"
fi

if ! $EXECUTE; then
  echo
  action "DRY-RUN 预览结束。使用 -e 才会实际删除。"
  exit 0
fi

# 安全模拟：检查 apt 依赖，防止误删或安装错误包
if [ ${#REMOVE_PKGS[@]} -gt 0 ]; then
  action "正在进行 apt 模拟检查 (防止破坏依赖)..."
  SIM="/tmp/pve-clean.sim"
  apt-get update -y >/dev/null 2>&1 || true

  set +e
  apt-get -s purge "${REMOVE_PKGS[@]}" >"$SIM" 2>&1
  CODE=$?
  set -e

  if [ $CODE -ne 0 ]; then
    info "模拟失败，系统依赖可能存在问题，请检查日志：$SIM"
    exit 1
  fi

  if grep -Ei "NEW packages will be installed" "$SIM"; then
    info "模拟显示将安装新包（可能是依赖错误的 unsigned 内核），操作已取消！"
    exit 1
  fi

  action "模拟检查通过，开始执行内核 purge..."
  apt-get purge -y "${REMOVE_PKGS[@]}"
else
  action "无需删除旧内核"
fi

# ---------- 深度系统清理 ----------

echo
action "开始执行系统深度清理..."

# 1. 基础清理
action "执行 apt autoremove..."
apt-get autoremove -y --purge || true

action "执行 apt autoclean (Round 1)..."
apt-get autoclean -y || true
apt-get clean -y || true

# 2. 清除 dpkg 残留配置 (RC Packages)
mapfile -t RC_PKGS < <(dpkg -l | awk '/^rc/ {print $2}' || true)
if [ ${#RC_PKGS[@]} -gt 0 ]; then
  action "发现并清除 dpkg 残留配置 (${#RC_PKGS[@]} 个)..."
  apt-get purge -y "${RC_PKGS[@]}" || true
else
  action "无 dpkg 残留配置"
fi

# 3. Grub 更新
if command -v update-grub >/dev/null; then
  action "更新 Grub 引导..."
  update-grub
fi

# 4. 日志与缓存深度清理
action "清理 systemd journal (保留 ${JOURNAL_AGE_DAYS} 天)..."
journalctl --vacuum-size="$JOURNAL_SIZE" || true
journalctl --vacuum-time="${JOURNAL_AGE_DAYS}d" || true

action "深度清理 /var/log 轮替文件..."
find /var/log -type f -regex '.*\.[0-9]+(\.gz)?$' -delete 2>/dev/null || true

if [ -d /var/log/journal ]; then
  action "深度清理 /var/log/journal 过期文件..."
  find /var/log/journal -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
fi

if [ -d /var/log.save ]; then
  action "清理 /var/log.save..."
  find /var/log.save -type f -regex '.*\.[0-9]+(\.gz)?$' -delete || true
fi

if [ -d /var/cache/e2fsck ]; then
  action "清理 fsck 缓存..."
  find /var/cache/e2fsck -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
fi

if [ -d /var/lib/clamav ]; then
  action "清理 ClamAV 缓存..."
  find /var/lib/clamav -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
fi

if [ -d /etc/apt/cache ]; then
  action "清理 apt 本地缓存..."
  find /etc/apt/cache -type f -mtime +"${JOURNAL_AGE_DAYS}" -delete || true
fi

# 5. 二次清理 (确保万无一失)
if [ -d /var/cache/apt/archives ]; then
  action "执行 apt autoclean (Round 2)..."
  apt-get autoclean -y || true
fi

# ---------- 废弃内核模块清理 ----------

MODDIR="/lib/modules"
if [ -d "$MODDIR" ]; then
  action "检查废弃的内核模块目录..."
  ALLOWED=()
  for v in "${KEEP_VERSIONS[@]}"; do
    ALLOWED+=("$v")
    [[ "$v" == *"-pve" ]] && ALLOWED+=("${v%-pve}") || ALLOWED+=("${v}-pve")
  done
  ALLOWED+=("$CURRENT_UNAME")

  mapfile -t DIRS < <(ls -1 "$MODDIR")
  for d in "${DIRS[@]}"; do
    if ! printf "%s\n" "${ALLOWED[@]}" | grep -qx "$d"; then
      action "删除废弃模块目录: $d"
      rm -rf "$MODDIR/$d"
    fi
  done
fi

echo
action "清理任务完成"
df -h /