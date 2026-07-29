#!/bin/bash

# 一键升级本地 AdGuard Home 脚本（带日志与颜色分离）
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m'
AGH_DIR='/opt/AdGuardHome' # AdGuard Home 安装目录
SCRIPT_PATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
LOGFILE="${SCRIPT_DIR}/adguard_update.log"
CHANNEL='release' # 发布渠道，可以是 'release' 或 'beta'
DOWNLOAD_URL_BASE="https://static.adtidy.org/adguardhome" # 默认下载源
STOPPED=0 # 标记 AdGuard Home 服务是否被脚本停止

# 日志函数：终端有颜色，日志为纯文本
function log() {
  local TIMESTAMP MSG CLEAN
  TIMESTAMP="$(date '+%F %T')"
  MSG="$1"
  CLEAN="$(echo -e "$MSG" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
  echo -e "[${TIMESTAMP}] $MSG"
  echo    "[${TIMESTAMP}] $CLEAN" >> "$LOGFILE"
}

# 清屏并打印标题
function banner() {
  clear
  echo -e "${GREEN}==============================================${NC}"
  echo -e "${GREEN}      AdGuard Home 一键升级脚本（叔叔版）     ${NC}"
  echo -e "${GREEN}==============================================${NC}"
}

# 检查 AdGuard Home 服务状态
function check_service_status() {
  if systemctl is-active --quiet AdGuardHome; then
    log "${GREEN}AdGuard Home 服务状态：正在运行。${NC}"
    return 0 # 正在运行
  else
    log "${YELLOW}AdGuard Home 服务状态：未运行或未安装为systemd服务。${NC}"
    return 1 # 未运行
  fi
}

# 模块1：升级 AdGuard Home
function do_upgrade() {
  : > "$LOGFILE"  # 清空旧日志，确保每次升级都从头记录
  log "${GREEN}日志文件位置：${LOGFILE}${NC}"

  log "${GREEN}>>> 检测 AdGuard Home 可执行文件...${NC}"
  if [[ ! -x "${AGH_DIR}/AdGuardHome" ]]; then
    log "${RED}错误：未找到 AdGuard Home 可执行文件 ${AGH_DIR}/AdGuardHome。${NC}"
    log "${RED}请检查 AGH_DIR 变量 (${AGH_DIR}) 是否正确，或 AdGuard Home 是否已安装。${NC}"
    exit 1
  fi

  log "${GREEN}>>> 检查服务状态...${NC}"
  if ! check_service_status; then
    log "${YELLOW}警告：AdGuard Home 服务当前未运行，脚本将尝试继续升级。${NC}"
    log "${YELLOW}如果升级后服务仍未启动，请手动检查。${NC}"
  fi

  log "${GREEN}>>> 检测本地版本...${NC}"
  LOCAL_VER_FULL="$("${AGH_DIR}/AdGuardHome" --version 2>&1)"
  # 从完整的版本字符串中提取纯版本号
  LOCAL_VER=$(echo "$LOCAL_VER_FULL" | grep -oP 'v[0-9.]+')
  log "${GREEN}本地版本: ${LOCAL_VER}${NC}"

  log "${GREEN}>>> 获取云端版本...${NC}"
  REMOTE_VER_RAW=$(curl -s --max-time 30 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep -oP '"tag_name":\s*"\Kv[0-9.]+')
  
  if [[ -z "$REMOTE_VER_RAW" ]]; then
    log "${RED}错误：获取远程版本失败。${NC}"
    log "${RED}请检查网络连接或 GitHub API 访问是否正常。${NC}"
    exit 1
  fi
  # 确保REMOTE_VER以'v'开头，并且只有一个'v'
  REMOTE_VER="v${REMOTE_VER_RAW#v}"

  log "${GREEN}云端版本: ${REMOTE_VER}${NC}"

  # 修复版本比较逻辑
  version_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ] && [ "$1" != "$2" ]
  }

  if ! version_lt "$LOCAL_VER" "$REMOTE_VER"; then
    log "${GREEN}本地已是最新版本 (${LOCAL_VER})，无需升级。${NC}"
    exit 0
  fi

  TMPDIR="/tmp/agh_update"
  log "${GREEN}>>> 清理临时目录 ${TMPDIR}...${NC}"
  rm -rf "$TMPDIR" && mkdir -p "$TMPDIR"

  OS="$(uname | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH='amd64' ;;
    i386|i686)    ARCH='386' ;;
    armv7l)       ARCH='armv7' ;;
    aarch64)      ARCH='arm64' ;;
    *) log "${RED}错误：不支持的架构：$ARCH。${NC}"; exit 1 ;;
  esac

  PKG="AdGuardHome_${OS}_${ARCH}.tar.gz"
  URL="${DOWNLOAD_URL_BASE}/${CHANNEL}/${PKG}"
  log "${GREEN}>>> 下载地址：${URL}${NC}"
  log "${GREEN}>>> 开始下载 AdGuard Home (${PKG})...${NC}"
  if ! curl -L --max-time 60 --retry 3 --retry-delay 5 -o "${TMPDIR}/${PKG}" "$URL"; then
    CURL_EXIT_CODE=$?
    log "${RED}错误：下载失败 (curl exit code: ${CURL_EXIT_CODE})。${NC}"
    log "${RED}请检查网络连接，或尝试更换下载源。当前服务将保持运行。${NC}"
    rm -rf "$TMPDIR"
    exit 1
  fi

  log "${GREEN}>>> 停止 AdGuard Home 服务...${NC}"
  if systemctl is-active --quiet AdGuardHome; then
    systemctl stop AdGuardHome &>/dev/null
    STOPPED=1
    log "${GREEN}使用 systemctl 停止服务成功。${NC}"
  else
    "${AGH_DIR}/AdGuardHome" -s stop &>/dev/null
    STOPPED=1
    log "${YELLOW}使用 AdGuardHome 命令停止服务。${NC}"
  fi


  log "${GREEN}>>> 解压并替换核心文件...${NC}"
  tar -xzf "${TMPDIR}/${PKG}" -C "$TMPDIR"
  if [[ -f "${TMPDIR}/AdGuardHome/AdGuardHome" ]]; then
      cp -f "${TMPDIR}/AdGuardHome/AdGuardHome" "${AGH_DIR}/AdGuardHome"
  else
      cp -f "${TMPDIR}/AdGuardHome" "${AGH_DIR}/AdGuardHome"
  fi
  
  if [[ -d "${TMPDIR}/AdGuardHome/web_src" ]]; then
    cp -rf "${TMPDIR}/AdGuardHome/web_src" "${AGH_DIR}/"
    log "${GREEN}已更新 web_src 目录。${NC}"
  elif [[ -d "${TMPDIR}/web_src" ]]; then
    cp -rf "${TMPDIR}/web_src" "${AGH_DIR}/"
    log "${GREEN}已更新 web_src 目录。${NC}"
  else
    log "${YELLOW}下载包中未找到 web_src 目录，跳过更新。${NC}"
  fi


  log "${GREEN}>>> 重启 AdGuard Home 服务...${NC}"
  if systemctl is-active --quiet AdGuardHome; then
    systemctl start AdGuardHome &>/dev/null && STOPPED=0
    log "${GREEN}使用 systemctl 启动服务成功。${NC}"
  else
    "${AGH_DIR}/AdGuardHome" -s start &>/dev/null && STOPPED=0
    log "${YELLOW}使用 AdGuard Home 命令启动服务。${NC}"
  fi

  rm -rf "$TMPDIR"
  log "${GREEN}>>> AdGuard Home 升级成功：${LOCAL_VER} → ${REMOTE_VER}${NC}"
  exit 0
}

# 模块2：添加定时任务
function add_cron() {
  log "${GREEN}>>> 准备添加定时任务（每两天凌晨3点自动升级）...${NC}" >> "$LOGFILE"
  CRON_LINE="0 3 */2 * * ${SCRIPT_PATH} --upgrade >/dev/null 2>&1"
  if crontab -l 2>/dev/null | grep -q -F "${CRON_LINE}"; then
    log "${YELLOW}提示：定时任务已存在，无需重复添加。${NC}" >> "$LOGFILE"
    echo -e "${YELLOW}提示：定时任务已存在，无需重复添加。${NC}"
  else
    ( crontab -l 2>/dev/null | grep -v -F "${SCRIPT_PATH} --upgrade"; echo "${CRON_LINE}" ) | crontab -
    log "${GREEN}>>> 定时任务添加成功：${CRON_LINE}${NC}" >> "$LOGFILE"
    echo -e "${GREEN}>>> 定时任务添加成功：${CRON_LINE}${NC}"
  fi
  read -p "$(echo -e "${GREEN}按任意键返回主菜单...${NC}")"
  return 0
}

# 模块3：查看定时任务
function view_cron() {
  log "${GREEN}>>> 查询当前 AdGuard Home 自动升级定时任务...${NC}" >> "$LOGFILE"
  CRON_ENTRY=$(crontab -l 2>/dev/null | grep -F "${SCRIPT_PATH} --upgrade")
  if [[ -z "$CRON_ENTRY" ]]; then
    log "${YELLOW}未找到 AdGuard Home 自动升级定时任务。${NC}" >> "$LOGFILE"
    echo -e "${YELLOW}未找到 AdGuard Home 自动升级定时任务。${NC}"
  else
    log "${GREEN}找到以下定时任务：${NC}" >> "$LOGFILE"
    log "${GREEN}${CRON_ENTRY}${NC}" >> "$LOGFILE"
    echo -e "${GREEN}找到以下定时任务：${NC}"
    echo -e "${GREEN}${CRON_ENTRY}${NC}"
  fi
  read -p "$(echo -e "${GREEN}按任意键返回主菜单...${NC}")"
  return 0
}

# 模块4：删除定时任务
function remove_cron() {
  log "${GREEN}>>> 准备删除 AdGuard Home 自动升级定时任务...${NC}" >> "$LOGFILE"
  CRON_LINE_PATTERN="${SCRIPT_PATH} --upgrade"
  if crontab -l 2>/dev/null | grep -q -F "${CRON_LINE_PATTERN}"; then
    ( crontab -l 2>/dev/null | grep -v -F "${CRON_LINE_PATTERN}" ) | crontab -
    log "${GREEN}成功删除 AdGuard Home 自动升级定时任务。${NC}" >> "$LOGFILE"
    echo -e "${GREEN}成功删除 AdGuard Home 自动升级定时任务。${NC}"
  else
    log "${YELLOW}未找到要删除的 AdGuard Home 自动升级定时任务。${NC}" >> "$LOGFILE"
    echo -e "${YELLOW}未找到要删除的 AdGuard Home 自动升级定时任务。${NC}"
  fi
  read -p "$(echo -e "${GREEN}按任意键返回主菜单...${NC}")"
  return 0
}

# 模块5：切换下载源 (示例，当前只提供一个固定源，但结构可扩展)
function switch_download_source() {
  log "${GREEN}>>> 当前下载源：${DOWNLOAD_URL_BASE}${NC}" >> "$LOGFILE"
  log "${YELLOW}此功能用于切换 AdGuard Home 的下载服务器。${NC}" >> "$LOGFILE"
  log "${YELLOW}目前仅支持默认源。如需修改，请手动编辑脚本中的 DOWNLOAD_URL_BASE 变量。${NC}" >> "$LOGFILE"
  log "${GREEN}暂无其他备用源选项。${NC}" >> "$LOGFILE"

  echo -e "${GREEN}>>> 当前下载源：${DOWNLOAD_URL_BASE}${NC}"
  echo -e "${YELLOW}此功能用于切换 AdGuard Home 的下载服务器。${NC}"
  echo -e "${YELLOW}目前仅支持默认源。如需修改，请手动编辑脚本中的 DOWNLOAD_URL_BASE 变量。${NC}"
  echo -e "${GREEN}暂无其他备用源选项。${NC}"
  
  read -p "$(echo -e "${GREEN}按任意键返回主菜单...${NC}")"
  return 0
}


# 容灾处理：如升级失败确保服务运行
trap 'if [[ "$STOPPED" == "1" ]]; then
  log "${RED}>>> 检测到脚本异常退出，尝试重启 AdGuard Home 服务...${NC}"
  if systemctl is-active --quiet AdGuardHome; then
    systemctl start AdGuardHome &>/dev/null
    log "${GREEN}使用 systemctl 启动服务成功。${NC}"
  else
    "${AGH_DIR}/AdGuardHome" -s start &>/dev/null
    log "${YELLOW}使用 AdGuard Home 命令启动服务。${NC}"
  fi
fi' EXIT

# 非交互参数（定时任务调用）
if [[ "$1" == "--upgrade" ]]; then
  do_upgrade
fi

# 交互菜单
while true; do
  banner
  echo -e "${GREEN}1) 升级本地的 AdGuard Home${NC}"
  echo -e "${GREEN}2) 添加定时任务 (每两天凌晨3点自动升级)${NC}"
  echo -e "${GREEN}3) 查看自动升级定时任务${NC}"
  echo -e "${GREEN}4) 删除自动升级定时任务${NC}"
  echo -e "${GREEN}5) 切换下载源 (高级)${NC}"
  echo -e "${GREEN}6) 退出脚本${NC}"
  echo
  read -p "$(echo -e "${GREEN}请输入选项 [1-6]:${NC}") " choice

  case "$choice" in
    1) do_upgrade ;;
    2) add_cron ;;
    3) view_cron ;;
    4) remove_cron ;;
    5) switch_download_source ;;
    6) exit 0 ;;
    *) log "${RED}无效选项，请重新输入。${NC}"; read -p "$(echo -e "${GREEN}按任意键继续...${NC}")" ;;
  esac
done