#!/bin/bash
# AdGuard Home 一键升级脚本（精简注释版，含日志/锁/回滚/多架构）
set -u

GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; NC='\e[0m'

AGH_DIR='/opt/AdGuardHome'
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOGFILE="${SCRIPT_DIR}/adguard_update.log"
CHANNEL='release'   # release 或 beta
VERSION_JSON_URL="https://static.adtidy.org/adguardhome/${CHANNEL}/version.json"
LOCKFILE="/tmp/adguard_update.lock"
STOPPED=0

# 终端彩色输出 + 日志文件纯文本记录
function log() {
  local TS MSG CLEAN
  TS="$(date '+%F %T')"; MSG="$1"
  CLEAN="$(echo -e "$MSG" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
  echo -e "[${TS}] $MSG"
  echo "[${TS}] $CLEAN" >> "$LOGFILE"
}

function banner() {
  clear
  echo -e "${GREEN}==============================================${NC}"
  echo -e "${GREEN}      AdGuard Home 一键升级脚本（优化版）      ${NC}"
  echo -e "${GREEN}==============================================${NC}"
}

function require_root() {
  [[ "$(id -u)" -eq 0 ]] || { log "${RED}错误：需要 root 权限运行。${NC}"; exit 1; }
}

# 优先判断 systemd 单元；没有则用 pgrep 检测独立进程，避免非 systemd 环境下误判
function check_service_status() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome.service'; then
    systemctl is-active --quiet AdGuardHome && { log "${GREEN}服务运行中（systemd）。${NC}"; return 0; }
    log "${YELLOW}服务未运行（systemd）。${NC}"; return 1
  else
    pgrep -f "${AGH_DIR}/AdGuardHome" >/dev/null 2>&1 && { log "${GREEN}服务运行中（进程）。${NC}"; return 0; }
    log "${YELLOW}服务未运行或未安装为 systemd 服务。${NC}"; return 1
  fi
}

function stop_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome.service'; then
    systemctl is-active --quiet AdGuardHome && { systemctl stop AdGuardHome &>/dev/null; STOPPED=1; log "${GREEN}systemctl 停止成功。${NC}"; }
  else
    "${AGH_DIR}/AdGuardHome" -s stop &>/dev/null || true
    STOPPED=1
    log "${YELLOW}使用 AdGuardHome 自带命令停止服务。${NC}"
  fi
}

function start_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome.service'; then
    systemctl start AdGuardHome &>/dev/null && STOPPED=0
    log "${GREEN}systemctl 启动成功。${NC}"
  else
    "${AGH_DIR}/AdGuardHome" -s start &>/dev/null && STOPPED=0
    log "${YELLOW}使用 AdGuardHome 自带命令启动服务。${NC}"
  fi
}

function version_lt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
}

function do_upgrade() {
  # 加锁防止并发升级
  exec 200>"$LOCKFILE"
  flock -n 200 || { log "${RED}错误：检测到另一个升级进程正在运行。${NC}"; exit 1; }

  : > "$LOGFILE"
  log "${GREEN}日志文件：${LOGFILE}${NC}"

  [[ -x "${AGH_DIR}/AdGuardHome" ]] || { log "${RED}错误：未找到 ${AGH_DIR}/AdGuardHome。${NC}"; exit 1; }

  check_service_status || log "${YELLOW}警告：服务当前未运行，仍尝试继续升级。${NC}"

  LOCAL_VER_FULL="$("${AGH_DIR}/AdGuardHome" --version 2>&1)"
  LOCAL_VER=$(echo "$LOCAL_VER_FULL" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  log "${GREEN}本地版本: ${LOCAL_VER}${NC}"

  # 用 static.adtidy.org（与下载地址同域名，实测比 static.adguard.com 更稳定）获取版本号
  VERSION_JSON=$(curl -s --max-time 30 -A "adguard-update-script" "$VERSION_JSON_URL")
  REMOTE_VER_RAW=$(echo "$VERSION_JSON" | grep -oP '"version"\s*:\s*"\K[^"]+' | head -n1)
  [[ -n "$REMOTE_VER_RAW" ]] || { log "${RED}错误：获取远程版本失败（${VERSION_JSON_URL}）。${NC}"; exit 1; }
  REMOTE_VER="v${REMOTE_VER_RAW#v}"
  log "${GREEN}云端版本: ${REMOTE_VER}${NC}"

  if ! version_lt "$LOCAL_VER" "$REMOTE_VER"; then
    log "${GREEN}已是最新版本 (${LOCAL_VER})，无需升级。${NC}"
    exit 0
  fi

  TMPDIR="$(mktemp -d /tmp/agh_update.XXXXXX)"

  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH='amd64' ;;
    i386|i686) ARCH='386' ;;
    armv5*) ARCH='armv5' ;;
    armv6*) ARCH='armv6' ;;
    armv7*) ARCH='armv7' ;;
    aarch64|arm64) ARCH='arm64' ;;
    mips) ARCH='mips_softfloat' ;;
    mipsle) ARCH='mipsle_softfloat' ;;
    mips64) ARCH='mips64_softfloat' ;;
    mips64le) ARCH='mips64le_softfloat' ;;
    ppc64le) ARCH='ppc64le' ;;
    riscv64) ARCH='riscv64' ;;
    *) log "${RED}错误：不支持的架构：$ARCH。${NC}"; rm -rf "$TMPDIR"; exit 1 ;;
  esac

  PKG="AdGuardHome_${OS}_${ARCH}.tar.gz"
  URL="https://static.adtidy.org/adguardhome/${CHANNEL}/${PKG}"
  log "${GREEN}下载地址：${URL}${NC}"

  if ! curl -L --max-time 60 --retry 3 --retry-delay 5 -o "${TMPDIR}/${PKG}" "$URL"; then
    log "${RED}错误：下载失败，服务保持运行。${NC}"; rm -rf "$TMPDIR"; exit 1
  fi

  if ! tar -tzf "${TMPDIR}/${PKG}" &>/dev/null; then
    log "${RED}错误：下载文件损坏或非法。${NC}"; rm -rf "$TMPDIR"; exit 1
  fi

  BACKUP="${AGH_DIR}/AdGuardHome.bak.$(date +%s)"
  cp -f "${AGH_DIR}/AdGuardHome" "$BACKUP"

  stop_service

  tar -xzf "${TMPDIR}/${PKG}" -C "$TMPDIR"
  NEW_BIN=""
  [[ -f "${TMPDIR}/AdGuardHome/AdGuardHome" ]] && NEW_BIN="${TMPDIR}/AdGuardHome/AdGuardHome"
  [[ -z "$NEW_BIN" && -f "${TMPDIR}/AdGuardHome" ]] && NEW_BIN="${TMPDIR}/AdGuardHome"

  if [[ -z "$NEW_BIN" ]]; then
    log "${RED}错误：解压后未找到二进制，回滚。${NC}"
    cp -f "$BACKUP" "${AGH_DIR}/AdGuardHome"; rm -f "$BACKUP"; start_service; rm -rf "$TMPDIR"; exit 1
  fi

  cp -f "$NEW_BIN" "${AGH_DIR}/AdGuardHome"
  chmod +x "${AGH_DIR}/AdGuardHome"

  # 关键修复：释放锁并关闭 fd 200，避免长驻的 AdGuardHome 进程继承该 fd 而永久占用锁
  flock -u 200
  exec 200>&-

  start_service
  sleep 2

  if ! check_service_status; then
    log "${RED}错误：新版本启动失败，回滚。${NC}"
    cp -f "$BACKUP" "${AGH_DIR}/AdGuardHome"; rm -f "$BACKUP"; start_service; rm -rf "$TMPDIR"; exit 1
  fi

  rm -f "$BACKUP"; rm -rf "$TMPDIR"
  log "${GREEN}升级成功：${LOCAL_VER} → ${REMOTE_VER}${NC}"
  exit 0
}

function add_cron() {
  CRON_LINE="0 3 * * * ${SCRIPT_PATH} --upgrade >/dev/null 2>&1"
  if crontab -l 2>/dev/null | grep -q -F "${SCRIPT_PATH} --upgrade"; then
    echo -e "${YELLOW}定时任务已存在。${NC}"
  else
    ( crontab -l 2>/dev/null | grep -v -F "${SCRIPT_PATH} --upgrade"; echo "${CRON_LINE}" ) | crontab -
    echo -e "${GREEN}定时任务添加成功：${CRON_LINE}${NC}"
  fi
}

function view_cron() {
  CRON_ENTRY=$(crontab -l 2>/dev/null | grep -F "${SCRIPT_PATH} --upgrade")
  [[ -n "$CRON_ENTRY" ]] && echo -e "${GREEN}${CRON_ENTRY}${NC}" || echo -e "${YELLOW}未找到定时任务。${NC}"
}

function remove_cron() {
  if crontab -l 2>/dev/null | grep -q -F "${SCRIPT_PATH} --upgrade"; then
    ( crontab -l 2>/dev/null | grep -v -F "${SCRIPT_PATH} --upgrade" ) | crontab -
    echo -e "${GREEN}定时任务已删除。${NC}"
  else
    echo -e "${YELLOW}未找到要删除的定时任务。${NC}"
  fi
}

function show_channel_info() {
  echo -e "${GREEN}当前发布渠道：${CHANNEL}${NC}"
  echo -e "${YELLOW}切换 release/beta 需手动编辑脚本中的 CHANNEL 变量。${NC}"
}

# 异常退出兜底：若服务被本脚本停止但未成功重启，尝试恢复
trap '[[ "$STOPPED" == "1" ]] && { log "${RED}检测到异常退出，尝试重启服务...${NC}"; start_service; }' EXIT

require_root

if [[ "${1:-}" == "--upgrade" ]]; then
  do_upgrade
fi

while true; do
  banner
  echo -e "${GREEN}1) 升级本地的 AdGuard Home${NC}"
  echo -e "${GREEN}2) 添加定时任务（每天凌晨3点自动检测并升级）${NC}"
  echo -e "${GREEN}3) 查看自动升级定时任务${NC}"
  echo -e "${GREEN}4) 删除自动升级定时任务${NC}"
  echo -e "${GREEN}5) 查看当前发布渠道${NC}"
  echo -e "${GREEN}6) 退出脚本${NC}"
  echo
  read -p "$(echo -e "${GREEN}请输入选项 [1-6]:${NC}") " choice
  case "$choice" in
    1) do_upgrade ;;
    2) add_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    3) view_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    4) remove_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    5) show_channel_info; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    6) exit 0 ;;
    *) log "${RED}无效选项。${NC}" ;;
  esac
done
