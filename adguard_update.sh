#!/bin/bash
# AdGuard Home 一键升级脚本（精简注释版，含日志/锁/回滚/多架构）
set -u

GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; NC='\e[0m'

AGH_DIR='/opt/AdGuardHome'
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOGFILE="${SCRIPT_DIR}/adguard_update.log"
CHANNEL='release' # release 或 beta
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
  echo -e "${GREEN} AdGuard Home 一键升级脚本（优化版） ${NC}"
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
    if systemctl is-active --quiet AdGuardHome; then
      systemctl stop AdGuardHome &>/dev/null
      STOPPED=1
      log "${GREEN}systemctl 停止成功。${NC}"
    fi
  else
    if "${AGH_DIR}/AdGuardHome" -s stop &>/dev/null; then
      STOPPED=1
      log "${YELLOW}使用 AdGuardHome 自带命令停止服务。${NC}"
    else
      # 停止失败(例如进程是手动启动、未经 -s install)：不要假装已停止，
      # 否则覆盖二进制后旧进程仍在跑，健康检查会误报升级成功
      STOPPED=0
      log "${RED}警告：停止服务失败，进程可能仍在运行，升级结果需人工复核。${NC}"
    fi
  fi
}

function start_service() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^AdGuardHome.service'; then
    if systemctl start AdGuardHome &>/dev/null; then
      STOPPED=0
      log "${GREEN}systemctl 启动成功。${NC}"
    else
      log "${RED}错误：systemctl 启动失败。${NC}"
    fi
  else
    if "${AGH_DIR}/AdGuardHome" -s start &>/dev/null; then
      STOPPED=0
      log "${YELLOW}使用 AdGuardHome 自带命令启动成功。${NC}"
    else
      log "${RED}错误：AdGuardHome 自带命令启动失败。${NC}"
    fi
  fi
}

function version_lt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
}

# 提取远程/本地版本号：优先尝试 grep -P(GNU PCRE)，Alpine/busybox 无 -P 时自动回退到 sed
function extract_version() {
  local input="$1" pattern_pcre="$2" pattern_sed="$3"
  local out
  out=$(echo "$input" | grep -oP "$pattern_pcre" 2>/dev/null | head -n1)
  if [[ -z "$out" ]]; then
    out=$(echo "$input" | sed -n "$pattern_sed" | head -n1)
  fi
  echo "$out"
}

# 释放升级锁 fd。注意：bash 关闭一个未打开/已关闭的 fd 本身不会报错(rc=0)，
# 不需要给 exec 加 2>/dev/null 兜底——那样写会把该重定向永久套在当前 shell 的 stderr 上，
# 导致 release_lock 之后所有走 stderr 的输出(如交互式 read -p 提示、命令报错)全部消失
function release_lock() {
  flock -u 200 2>/dev/null
  exec 200>&-
}

function do_upgrade() {
  # 加锁防止并发升级
  exec 200>"$LOCKFILE"
  flock -n 200 || { log "${RED}错误：检测到另一个升级进程正在运行。${NC}"; return 1; }

  : > "$LOGFILE"
  log "${GREEN}日志文件：${LOGFILE}${NC}"

  [[ -x "${AGH_DIR}/AdGuardHome" ]] || { log "${RED}错误：未找到 ${AGH_DIR}/AdGuardHome。${NC}"; release_lock; return 1; }

  check_service_status || log "${YELLOW}警告：服务当前未运行，仍尝试继续升级。${NC}"

  LOCAL_VER_FULL="$("${AGH_DIR}/AdGuardHome" --version 2>&1)"
  LOCAL_VER=$(extract_version "$LOCAL_VER_FULL" 'v[0-9]+\.[0-9]+\.[0-9]+' 's/.*\(v[0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
  # 本地版本解析为空时 version_lt "" "$REMOTE_VER" 会被判定为真而继续升级，必须先拦住
  [[ -n "$LOCAL_VER" ]] || { log "${RED}错误：无法解析本地版本号，中止升级。${NC}"; release_lock; return 1; }
  log "${GREEN}本地版本: ${LOCAL_VER}${NC}"

  # 用 static.adtidy.org（与下载地址同域名，实测比 static.adguard.com 更稳定）获取版本号
  VERSION_JSON=$(curl -s --max-time 30 -A "adguard-update-script" "$VERSION_JSON_URL")
  REMOTE_VER_RAW=$(extract_version "$VERSION_JSON" '"version"\s*:\s*"\K[^"]+' 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [[ -n "$REMOTE_VER_RAW" ]] || { log "${RED}错误：获取远程版本失败（${VERSION_JSON_URL}）。${NC}"; release_lock; return 1; }
  REMOTE_VER="v${REMOTE_VER_RAW#v}"
  log "${GREEN}云端版本: ${REMOTE_VER}${NC}"

  if ! version_lt "$LOCAL_VER" "$REMOTE_VER"; then
    log "${GREEN}已是最新版本 (${LOCAL_VER})，无需升级。${NC}"
    release_lock
    return 0
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
    *) log "${RED}错误：不支持的架构：$ARCH。${NC}"; rm -rf "$TMPDIR"; release_lock; return 1 ;;
  esac

  PKG="AdGuardHome_${OS}_${ARCH}.tar.gz"
  URL="https://static.adtidy.org/adguardhome/${CHANNEL}/${PKG}"
  log "${GREEN}下载地址：${URL}${NC}"

  if ! curl -L --max-time 60 --retry 3 --retry-delay 5 -o "${TMPDIR}/${PKG}" "$URL"; then
    log "${RED}错误：下载失败，服务保持运行。${NC}"; rm -rf "$TMPDIR"; release_lock; return 1
  fi

  if ! tar -tzf "${TMPDIR}/${PKG}" &>/dev/null; then
    log "${RED}错误：下载文件损坏或非法。${NC}"; rm -rf "$TMPDIR"; release_lock; return 1
  fi

  BACKUP_BIN="${AGH_DIR}/AdGuardHome.bak.$(date +%s)"
  cp -f "${AGH_DIR}/AdGuardHome" "$BACKUP_BIN"

  # 同时备份配置文件：若新版本迁移了配置 schema 后崩溃，仅回滚二进制会导致
  # 旧版本读不懂被迁移过的新配置，必须把 yaml 也一起备份/回滚
  BACKUP_YAML=""
  if [[ -f "${AGH_DIR}/AdGuardHome.yaml" ]]; then
    BACKUP_YAML="${AGH_DIR}/AdGuardHome.yaml.bak.$(date +%s)"
    cp -f "${AGH_DIR}/AdGuardHome.yaml" "$BACKUP_YAML"
  fi

  stop_service

  tar -xzf "${TMPDIR}/${PKG}" -C "$TMPDIR"
  NEW_BIN=""
  [[ -f "${TMPDIR}/AdGuardHome/AdGuardHome" ]] && NEW_BIN="${TMPDIR}/AdGuardHome/AdGuardHome"
  [[ -z "$NEW_BIN" && -f "${TMPDIR}/AdGuardHome" ]] && NEW_BIN="${TMPDIR}/AdGuardHome"

  if [[ -z "$NEW_BIN" ]]; then
    log "${RED}错误：解压后未找到二进制，回滚。${NC}"
    cp -f "$BACKUP_BIN" "${AGH_DIR}/AdGuardHome"
    [[ -n "$BACKUP_YAML" ]] && cp -f "$BACKUP_YAML" "${AGH_DIR}/AdGuardHome.yaml"
    rm -f "$BACKUP_BIN" "$BACKUP_YAML"
    start_service; rm -rf "$TMPDIR"; release_lock; return 1
  fi

  cp -f "$NEW_BIN" "${AGH_DIR}/AdGuardHome"
  chmod +x "${AGH_DIR}/AdGuardHome"

  # 关键修复：释放锁并关闭 fd 200，避免长驻的 AdGuardHome 进程继承该 fd 而永久占用锁
  release_lock

  start_service
  sleep 2

  if ! check_service_status; then
    log "${RED}错误：新版本启动失败，回滚。${NC}"
    cp -f "$BACKUP_BIN" "${AGH_DIR}/AdGuardHome"
    [[ -n "$BACKUP_YAML" ]] && cp -f "$BACKUP_YAML" "${AGH_DIR}/AdGuardHome.yaml"
    rm -f "$BACKUP_BIN" "$BACKUP_YAML"
    start_service; rm -rf "$TMPDIR"
    return 1
  fi

  rm -f "$BACKUP_BIN" "$BACKUP_YAML"; rm -rf "$TMPDIR"
  log "${GREEN}升级成功：${LOCAL_VER} → ${REMOTE_VER}${NC}"
  return 0
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
  exit $?
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
    1) do_upgrade; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    2) add_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    3) view_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    4) remove_cron; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    5) show_channel_info; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
    6) exit 0 ;;
    *) log "${RED}无效选项。${NC}"; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
  esac
done
