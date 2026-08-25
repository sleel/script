#!/bin/sh
# ==============================================================================
# 通用 Shell 个性化管理器
# 自动检测目标用户的登录 shell 类型：
# - bash -> 写入 ~/.bashrc（bash 风格提示符 + 登录横幅）
# - 非bash(ash等) -> 写入 ~/.profile（POSIX 风格提示符 + 登录横幅）
# 安装器本身用 #!/bin/sh 编写，在 bash 和 ash(BusyBox) 环境下都能直接运行。
# 适用：Debian / Ubuntu / Proxmox VE / CentOS / Rocky / Alpine
# 注：zsh 用户的登录 shell 会被归入 POSIX 模式写入 ~/.profile，但 zsh 默认不读取
# .profile（除非配置为登录 shell 且启用了兼容读取），该场景需要用户自行确认适用性。
# ==============================================================================
set -u

if [ "$(id -u)" -ne 0 ]; then
echo "错误：此脚本需要以 root 权限运行。"
exit 1
fi

TARGET_USER="root"
if [ -n "${SUDO_USER:-}" ]; then
TARGET_USER="$SUDO_USER"
fi

_passwd_line="$(getent passwd "$TARGET_USER" 2>/dev/null)"
if [ -z "$_passwd_line" ]; then
_passwd_line="$(grep "^${TARGET_USER}:" /etc/passwd 2>/dev/null)"
fi

TARGET_HOME="$(printf '%s' "$_passwd_line" | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/root}"
TARGET_SHELL="$(printf '%s' "$_passwd_line" | cut -d: -f7)"

# 目标用户shell明确是bash才用bash模式；明确不是bash就用POSIX模式，
# 不受"系统别处是否装了bash"影响，避免写到用户实际不会读取的文件里。
case "$TARGET_SHELL" in
*/bash) MODE="bash" ;;
"")
if command -v bash >/dev/null 2>&1; then MODE="bash"; else MODE="posix"; fi
;;
*) MODE="posix" ;;
esac

if [ "$MODE" = "bash" ]; then
RC_FILE="${TARGET_HOME}/.bashrc"
else
RC_FILE="${TARGET_HOME}/.profile"
fi
RC_BACKUP="${RC_FILE}.bak"
HUSHLOGIN_FILE="${TARGET_HOME}/.hushlogin"

BEGIN_MARKER="# --- Custom Shell Personalization (managed block) ---"
END_MARKER="# --- End Custom Shell Personalization ---"

info() { echo " -> $*"; }
section() { echo; echo "$*"; }

write_bash_block() {
cat >> "$RC_FILE" << 'EOF'
# --- Custom Shell Personalization (managed block) ---
LIGHT_GREEN='\[\033[1;32m\]'
LIGHT_CYAN='\[\033[1;36m\]'
LIGHT_RED='\[\033[1;31m\]'
NC='\[\033[0m\]'
PS1="[${LIGHT_RED}\u${NC}@${LIGHT_CYAN}\h${NC}] ${LIGHT_GREEN}\w${NC} \$ ${NC}"

__show_login_banner() {
_lb='\033[1;34m'; _ly='\033[1;33m'; _lg='\033[1;32m'; _nc='\033[0m'
if command -v pveversion >/dev/null 2>&1 || [ -d /etc/pve ]; then
_ver="$(dpkg-query --showformat='${Version}' --show pve-manager 2>/dev/null | cut -d'/' -f1)"
if [ -n "$_ver" ]; then _title="Welcome to Proxmox VE (${_ver})"; else _title="Welcome to Proxmox VE"; fi
elif [ -r /etc/os-release ]; then
. /etc/os-release
if [ -n "${PRETTY_NAME:-}" ]; then _title="Welcome to ${PRETTY_NAME}"; else _title="Welcome to ${NAME:-$(uname -s)}"; fi
else
_title="Welcome to $(uname -s) $(uname -r)"
fi
_bw=69; _iw=65; _tl=${#_title}
if [ "$_tl" -gt "$_iw" ]; then _title=$(printf '%s' "$_title" | cut -c1-"$_iw"); _tl=$_iw; fi
_pt=$((_iw - _tl)); _pl=$((_pt / 2)); _pr=$((_pt - _pl))
_ls=$(printf "%${_pl}s" ""); _rs=$(printf "%${_pr}s" ""); _bl=$(printf "%${_iw}s" "")
_bd=$(printf '%*s' "$_bw" '' | tr ' ' '#')
printf "${_lb}"
printf "%s\n" "$_bd"
printf "# %s #\n" "$_bl"
printf "# %s%s%s #\n" "$_ls" "$_title" "$_rs"
printf "# %s #\n" "$_bl"
printf "%s\n" "$_bd"
printf "${_nc}\n"
printf " ${_ly}%-15s${_nc} : %s\n" "Hostname" "$(hostname)"
printf " ${_ly}%-15s${_nc} : %s\n" "Kernel" "$(uname -r)"
printf " ${_ly}%-15s${_nc} : %s\n" "Uptime" "$(uptime -p 2>/dev/null | sed 's/up //' || uptime)"
printf "\n"
printf " ${_lg}%-15s${_nc} : %s\n" "CPU Load" "$(uptime | awk -F'load average: ' '{print $2}' 2>/dev/null || echo n/a)"
printf " ${_lg}%-15s${_nc} : %s\n" "Memory Usage" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3"/"$2" ("$7" available)"}' || echo n/a)"
printf "\n"
if command -v last >/dev/null 2>&1; then
_raw="$(last -2 2>/dev/null | sed -n '2p')"
if [ -n "$_raw" ]; then
_lu=$(printf '%s' "$_raw" | awk '{print $1}')
_lh=$(printf '%s' "$_raw" | awk '{print $3}')
_lt=$(printf '%s' "$_raw" | awk '{print $4,$5,$6,$7}')
printf " ${_ly}%-15s${_nc} : %s\n\n" "Last login" "${_lu} from ${_lh} at ${_lt}"
fi
fi

case "$0" in
-*) printf '\033[H\033[2J'; __show_login_banner ;;
esac
# --- End Custom Shell Personalization ---
EOF
}

write_posix_block() {
cat >> "$RC_FILE" << 'EOF'
# --- Custom Shell Personalization (managed block) ---
ESC="$(printf '\033')"
export PS1="${ESC}[1;31m\$(whoami)${ESC}[0m@${ESC}[1;36m\$(hostname)${ESC}[0m ${ESC}[1;32m\$(pwd)${ESC}[0m \$ "

show_login_banner() {
_esc="$(printf '\033')"
_lb="${_esc}[1;34m"; _ly="${_esc}[1;33m"; _lg="${_esc}[1;32m"; _nc="${_esc}[0m"
if [ -r /etc/os-release ]; then
. /etc/os-release
if [ -n "${PRETTY_NAME:-}" ]; then _title="Welcome to ${PRETTY_NAME}"; else _title="Welcome to ${NAME:-$(uname -s)}"; fi
else
_title="Welcome to $(uname -s) $(uname -r)"
fi
_bw=69; _iw=65; _tl=${#_title}
if [ "$_tl" -gt "$_iw" ]; then _title=$(printf '%s' "$_title" | cut -c1-"$_iw"); _tl=$_iw; fi
_pt=$((_iw - _tl)); _pl=$((_pt / 2)); _pr=$((_pt - _pl))
_ls=$(printf "%${_pl}s" ""); _rs=$(printf "%${_pr}s" ""); _bl=$(printf "%${_iw}s" "")
_bd=$(printf '%*s' "$_bw" '' | tr ' ' '#')
printf "%s" "$_lb"
printf "%s\n" "$_bd"
printf "# %s #\n" "$_bl"
printf "# %s%s%s #\n" "$_ls" "$_title" "$_rs"
printf "# %s #\n" "$_bl"
printf "%s\n" "$_bd"
printf "%s\n" "$_nc"
_uraw="$(uptime 2>/dev/null)"
_uclean=$(printf '%s' "$_uraw" | awk -F'up' '{print $2}' | awk -F', *[0-9]+ user' '{print $1}' | sed 's/^ *//;s/ *$//;s/  */ /g')
_uload=$(printf '%s' "$_uraw" | awk -F'load average: ' '{print $2}')
printf " %s%-15s%s : %s\n" "$_ly" "Hostname" "$_nc" "$(hostname)"
printf " %s%-15s%s : %s\n" "$_ly" "Kernel" "$_nc" "$(uname -r)"
printf " %s%-15s%s : %s\n" "$_ly" "Uptime" "$_nc" "${_uclean:-n/a}"
printf "\n"
printf " %s%-15s%s : %s\n" "$_lg" "CPU Load" "$_nc" "${_uload:-n/a}"
printf " %s%-15s%s : %s\n" "$_lg" "Memory Usage" "$_nc" "$(free -h 2>/dev/null | awk '/^Mem:/ {print $3"/"$2}' || echo n/a)"
printf "\n"
if command -v last >/dev/null 2>&1; then
_lraw="$(last -n 2 2>/dev/null | sed -n '2p')"
if [ -n "$_lraw" ]; then
_lu=$(printf '%s' "$_lraw" | awk '{print $1}')
_lh=$(printf '%s' "$_lraw" | awk '{print $3}')
_lt=$(printf '%s' "$_lraw" | awk '{print $4,$5,$6,$7}')
printf " %s%-15s%s : %s from %s at %s\n\n" "$_ly" "Last login" "$_nc" "$_lu" "$_lh" "$_lt"
fi
fi

case "$0" in
-*) printf '\033[H\033[2J'; show_login_banner ;;
esac
# --- End Custom Shell Personalization ---
EOF
}

# 删除已存在的托管区块。用单引号包裹整段 sed 表达式，避免混合双引号+\$ 转义
# 带来的可读性噪音（此前正是这类转义混乱导致地址结束定界符 / 被漏写，sed 报
# "unknown command" 并以非零码退出，而脚本没检查退出码，照样打印"已清除旧区块"，
# 于是每次重装都在文件末尾追加一份新区块，区块数量 1→2→3 不断堆积）。
remove_managed_block() {
sed -i '/^# --- Custom Shell Personalization (managed block) ---$/,/^# --- End Custom Shell Personalization ---$/d' "$RC_FILE"
}

install_settings() {
section "--- 安装/更新 (shell类型: ${MODE}, 目标文件: ${RC_FILE}) ---"
section "[1/4] 备份原始文件..."
if [ -f "$RC_FILE" ] && [ ! -f "$RC_BACKUP" ] && ! grep -qF "$BEGIN_MARKER" "$RC_FILE"; then
cp -p "$RC_FILE" "$RC_BACKUP"
info "已备份 $(basename "$RC_FILE")"
else
info "备份已存在或源文件不存在, 跳过。"
fi
section "[2/4] 清理旧的自定义区块（如有）..."
touch "$RC_FILE"
if grep -qF "$BEGIN_MARKER" "$RC_FILE"; then
if remove_managed_block; then
info "已清除旧区块，准备更新。"
else
info "警告：旧区块清除失败，中止以防区块堆积。"
return 1
fi
fi
if [ "$MODE" = "bash" ]; then
section "[3/4] 创建 ~/.hushlogin（抑制登录时的内核行/版权声明/Last login）..."
touch "$HUSHLOGIN_FILE"
info "已创建 $HUSHLOGIN_FILE"
else
section "[3/4] (POSIX 模式跳过 hushlogin)"
fi
section "[4/4] 写入配置..."
if [ "$MODE" = "bash" ]; then write_bash_block; else write_posix_block; fi
info "配置写入完成。"
echo "======================================================================"
echo "完成！请重新登录一次查看效果 (目标文件: ${RC_FILE})。"
echo "======================================================================"
}

restore_settings() {
section "--- 恢复为系统默认设置 ---"
if [ -f "$RC_BACKUP" ]; then
cp -p "$RC_BACKUP" "$RC_FILE"
info "$(basename "$RC_FILE") 已从备份恢复。"
else
# 无备份时(例如安装时才新建的 rc 文件)不能假装恢复成功：直接删掉托管区块，
# 删完后如果文件已无实质内容就把文件本身删掉，还原到"从未安装过"的状态
info "未找到备份文件，改为直接移除托管区块。"
if grep -qF "$BEGIN_MARKER" "$RC_FILE" 2>/dev/null; then
if remove_managed_block; then
info "已移除托管区块。"
if [ ! -s "$RC_FILE" ]; then
rm -f "$RC_FILE"
info "$(basename "$RC_FILE") 内容已清空，已删除该文件。"
fi
else
info "警告：移除托管区块失败，请手动检查 $RC_FILE"
fi
else
info "未检测到托管区块，无需处理。"
fi
fi
if [ "$MODE" = "bash" ] && [ -f "$HUSHLOGIN_FILE" ]; then
rm -f "$HUSHLOGIN_FILE"
info "已删除 ~/.hushlogin。"
fi
echo "恢复完成。"
}

audit_settings() {
section "--- 审查当前状态 (shell类型: ${MODE}, 目标文件: ${RC_FILE}) ---"
_issues=0
_audit_tmp="$(mktemp 2>/dev/null || echo /tmp/_shell_personalizer_audit_$$)"

if [ ! -f "$RC_FILE" ]; then
echo " ℹ 目标文件尚不存在（还没安装过，属于正常状态）"
echo
echo "结论：干净（全新环境，可以直接安装）。"
rm -f "$_audit_tmp"
return
fi

_cnt=$(grep -c "Custom Shell Personalization (managed block)" "$RC_FILE" 2>/dev/null); _cnt=${_cnt:-0}
if [ "$_cnt" -gt 1 ]; then echo " ⚠ 重复区块=$_cnt"; _issues=$((_issues+1))
elif [ "$_cnt" -eq 1 ]; then echo " ✅ 区块唯一"; else echo " ℹ 尚未安装"; fi

if [ "$MODE" = "bash" ]; then
bash -n "$RC_FILE" 2>"$_audit_tmp" && echo " ✅ 语法正常" || { echo " ⚠ 语法错误"; cat "$_audit_tmp"; _issues=$((_issues+1)); }
else
sh -n "$RC_FILE" 2>"$_audit_tmp" && echo " ✅ 语法正常" || { echo " ⚠ 语法错误"; cat "$_audit_tmp"; _issues=$((_issues+1)); }
fi
rm -f "$_audit_tmp"

if [ -f "$RC_BACKUP" ]; then
echo " ✅ 备份存在: $RC_BACKUP"
else
echo " ℹ 无备份文件（如果从未安装过，这是正常的）"
fi

[ "$_issues" -eq 0 ] && echo "结论：干净。" || echo "结论：发现 $_issues 项问题。"
}

show_menu() {
while true; do
clear 2>/dev/null || printf '\033[H\033[2J'
echo "======================================================"
echo " Shell 个性化管理器"
echo " 目标用户: ${TARGET_USER} | 检测到 shell: ${TARGET_SHELL:-未知} | 模式: ${MODE}"
echo "======================================================"
echo
echo " 1) 安装或更新个性化配置"
echo " 2) 恢复为系统默认设置"
echo " 3) 审查当前状态（只读，不修改）"
echo " 4) 退出"
echo
printf "请输入您的选择 [1-4]: "
# stdin 关闭(如 ssh host ./script 不带 -t、cron 误调、< /dev/null)时 read 返回非零，
# 若不处理会落入 *) 分支"无效输入"再 sleep 循环，造成无限循环。read 失败直接退出。
read choice || { echo; echo "检测到输入流已关闭，退出。"; exit 0; }
case "$choice" in
1) install_settings; exit 0 ;;
2) restore_settings; exit 0 ;;
3) audit_settings; printf "按回车返回菜单..."; read _d || exit 0 ;;
4) echo "再见！"; exit 0 ;;
*) echo "无效输入"; sleep 1 ;;
esac
done
}

show_menu
