#!/bin/bash

# ==============================================================================
# Proxmox VE Shell Personalization Manager (Interactive Menu Version v3.0)
# Description: Installs or restores a custom shell theme via an interactive menu.
# FIX: v3.0 fixes the PS1 rendering bug for command history.
# Author: Gemini
# ==============================================================================

# --- Safety Check: Ensure the script is run as root ---
if [ "$(id -u)" -ne 0 ]; then
  echo "错误：此脚本需要以 root 权限运行。"
  exit 1
fi

# --- File Definitions ---
BASHRC_FILE="$HOME/.bashrc"
BASHRC_BACKUP="$HOME/.bashrc.bak"
MOTD_FILE="/etc/motd"
MOTD_BACKUP="/etc/motd.bak"
CUSTOM_MOTD_SCRIPT="/etc/update-motd.d/00-custom-header"
DEFAULT_UNAME_SCRIPT="/etc/update-motd.d/10-uname"

#==============================
# --- INSTALL FUNCTION ---
#==============================
install_settings() {
  echo
  echo "--- 模式: [安装] 个性化配置 ---"
  echo

  # 1. Backup original files
  echo "[步骤 1/4] 检查并备份原始文件..."
  if [ ! -f "$BASHRC_BACKUP" ]; then cp "$BASHRC_FILE" "$BASHRC_BACKUP"; echo "  -> 已备份 .bashrc"; else echo "  -> .bashrc 备份已存在, 跳过。"; fi
  if [ ! -f "$MOTD_BACKUP" ]; then cp "$MOTD_FILE" "$MOTD_BACKUP"; echo "  -> 已备份 /etc/motd"; else echo "  -> /etc/motd 备份已存在, 跳过。"; fi
  echo

  # 2. Configure the custom shell prompt (PS1)
  echo "[步骤 2/4] 配置自定义 Shell 提示符..."
  PROMPT_MARKER="# --- Custom Shell Prompt Configuration (Bright Colors) ---"
  # Remove old block if it exists, to ensure update
  if grep -qF "$PROMPT_MARKER" "$BASHRC_FILE"; then
    sed -i "/$PROMPT_MARKER/,/PS1=.*/d" "$BASHRC_FILE"
    echo "  -> 已移除旧的提示符配置，准备更新..."
  fi
  
  cat << 'EOF' >> "$BASHRC_FILE"

# --- Custom Shell Prompt Configuration (Bright Colors) ---
# Added by Personalization Script v3.0
LIGHT_GREEN='\[\033[1;32m\]'
LIGHT_CYAN='\[\033[1;36m\]'
LIGHT_RED='\[\033[1;31m\]'
NC='\[\033[0m\]'

# CORRECTED PS1 to fix command history rendering bug
PS1="[${LIGHT_RED}\u${NC}@${LIGHT_CYAN}\h${NC}] ${LIGHT_GREEN}\w${NC} \$ ${LIGHT_GREEN}"
EOF
  echo "  -> 提示符配置已成功写入。"
  echo

  # 3. Create the custom MOTD
  echo "[步骤 3/4] 创建自定义 MOTD..."
  cat << 'EOF' > "$CUSTOM_MOTD_SCRIPT"
#!/bin/sh
LIGHT_BLUE='\033[1;34m'; LIGHT_YELLOW='\033[1;33m'; LIGHT_GREEN='\033[1;32m'; NC='\033[0m';
printf "${LIGHT_BLUE}"; printf "#####################################################################\n"; printf "#                                                                   #\n"; printf "#                  Welcome to Proxmox VE 9                          #\n"; printf "#                                                                   #\n"; printf "#####################################################################\n"; printf "${NC}\n";
printf " ${LIGHT_YELLOW}%-15s${NC} : %s\n" "Hostname" "$(hostname)"; printf " ${LIGHT_YELLOW}%-15s${NC} : %s\n" "Kernel" "$(uname -r)"; printf " ${LIGHT_YELLOW}%-15s${NC} : %s\n" "Uptime" "$(uptime -p | sed 's/up //')"; printf "\n";
printf " ${LIGHT_GREEN}%-15s${NC} : %s\n" "CPU Load" "$(uptime | awk -F'load average: ' '{print $2}')"; printf " ${LIGHT_GREEN}%-15s${NC} : %s\n" "Memory Usage" "$(free -h | grep Mem | awk '{print $3 "/" $2 " (" $7 " available)"}')"; printf "\n";
EOF
  chmod +x "$CUSTOM_MOTD_SCRIPT"
  echo "  -> 自定义 MOTD 脚本已创建并设为可执行。"
  echo

  # 4. Disable conflicting MOTD items
  echo "[步骤 4/4] 禁用默认 MOTD 项..."
  if [ -f "$DEFAULT_UNAME_SCRIPT" ]; then chmod -x "$DEFAULT_UNAME_SCRIPT"; echo "  -> 已禁用 '10-uname' 脚本。"; fi
  truncate -s 0 "$MOTD_FILE"
  echo "  -> 已清空 /etc/motd 文件。"
  echo

  echo "======================================================================"
  echo "🎉 [安装] 操作完成！🎉"
  echo "请运行 'source ~/.bashrc' 并重新登录以查看所有更改。"
  echo "======================================================================"
}

#==============================
# --- RESTORE FUNCTION ---
#==============================
restore_settings() {
  echo
  echo "--- 模式: [恢复] 默认设置 ---"
  echo

  # 1. Restore .bashrc from backup
  echo "[步骤 1/3] 恢复 .bashrc..."
  if [ -f "$BASHRC_BACKUP" ]; then
    # Also remove the custom prompt block before restoring, just in case
    PROMPT_MARKER="# --- Custom Shell Prompt Configuration (Bright Colors) ---"
    sed -i "/$PROMPT_MARKER/,/PS1=.*/d" "$BASHRC_FILE"
    cp "$BASHRC_BACKUP" "$BASHRC_FILE"
    echo "  -> .bashrc 已从备份恢复。"
  else
    echo "  -> 未找到 .bashrc 备份文件, 跳过。"
  fi
  echo

  # 2. Restore MOTD from backup
  echo "[步骤 2/3] 恢复 /etc/motd..."
  if [ -f "$MOTD_BACKUP" ]; then cp "$MOTD_BACKUP" "$MOTD_FILE"; echo "  -> /etc/motd 已从备份恢复。"; else echo "  -> 未找到 /etc/motd 备份文件, 跳过。"; fi
  echo

  # 3. Remove custom MOTD and re-enable defaults
  echo "[步骤 3/3] 移除自定义 MOTD 并重置默认项..."
  if [ -f "$CUSTOM_MOTD_SCRIPT" ]; then rm "$CUSTOM_MOTD_SCRIPT"; echo "  -> 已删除自定义 MOTD 脚本。"; else echo "  -> 自定义 MOTD 脚本不存在, 跳过。"; fi
  if [ -f "$DEFAULT_UNAME_SCRIPT" ]; then chmod +x "$DEFAULT_UNAME_SCRIPT"; echo "  -> 已重新启用 '10-uname' 脚本。"; fi
  echo

  echo "======================================================================"
  echo "✅ [恢复] 操作完成！✅"
  echo "请运行 'source ~/.bashrc' 并重新登录以查看还原效果。"
  echo "======================================================================"
}

#==============================
# --- MAIN MENU FUNCTION ---
#==============================
show_menu() {
  while true; do
    clear
    echo "======================================================"
    echo "      Proxmox VE Shell 个性化管理器 (v3.0)"
    echo "======================================================"
    echo
    echo "请选择一个操作："
    echo "  1) 安装或更新个性化主题 (已修复显示Bug)"
    echo "  2) 恢复为系统默认设置"
    echo "  3) 退出脚本"
    echo
    read -p "请输入您的选择 [1-3]: " choice

    case "$choice" in
      1) install_settings; exit 0 ;;
      2) restore_settings; exit 0 ;;
      3) echo "再见！"; exit 0 ;;
      *) echo; echo "无效输入，请输入 1, 2, 或 3。"; sleep 2 ;;
    esac
  done
}

# --- SCRIPT ENTRY POINT ---
show_menu
