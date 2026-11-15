#!/bin/bash
set -euo pipefail

TARGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
BACKUP_DIR="/var/backups/pve-nag"
PAUSE_FLAG="${BACKUP_DIR}/.paused"
HOOK_FILE="/etc/apt/apt.conf.d/99-pve-remove-nag"
LOCK_FILE="/run/lock/pve-remove-nag.lock"
MODE=""
HOOK_MODE=false
TMP_FILE=""

trap '[[ -n "${TMP_FILE:-}" ]] && rm -f "$TMP_FILE"' EXIT

case "${1:-}" in
    ""|"--status"|"-s")
        MODE="status"
        ;;
    "-e"|"--exec")
        MODE="patch"
        ;;
    "--hook")
        MODE="hook"
        ;;
    "--unhook")
        MODE="unhook"
        ;;
    "--restore"|"-r")
        MODE="restore"
        ;;
    "--auto")
        MODE="patch"
        HOOK_MODE=true
        ;;
    *)
        echo "用法: $0 [-e | --hook | --unhook | --restore | --status]" >&2
        exit 2
        ;;
esac

log_msg() {
    local level="$1"
    local msg="$2"
    echo "[$level] $msg"
    logger -t "pve-remove-nag" "[$level] $msg" || true
}

finish() {
    local code=$1
    [[ "$HOOK_MODE" == "true" ]] && exit 0
    exit "$code"
}

if [[ "$EUID" -ne 0 ]]; then
    echo "[ERROR] 请使用 root 权限运行。" >&2
    exit 1
fi

export UNPATCHED_RE="res\\.data\\.status\\.toLowerCase\\(\\)\\s*!==\\s*'active'(?=\\s*\\)\\s*\\{\\s*Ext\\.Msg\\.show\\(\\{\\s*title:\\s*gettext\\('No valid subscription'\\))"
export PATCHED_RE="res === null \\|\\|\\s*res === undefined \\|\\|\\s*!res \\|\\|\\s*false(?=\\s*\\)\\s*\\{\\s*Ext\\.Msg\\.show\\(\\{\\s*title:\\s*gettext\\('No valid subscription'\\))"

# ==================== 模式 1：默认只读体检 (--status) ====================
if [[ "$MODE" == "status" ]]; then
    if [[ ! -s "$TARGET_FILE" ]]; then
        echo "[ERROR] 目标文件不存在或为空: $TARGET_FILE"
        exit 1
    fi

    U_CNT=$(perl -0777 -ne '$c = () = /$ENV{UNPATCHED_RE}/g; print $c' "$TARGET_FILE")
    P_CNT=$(perl -0777 -ne '$c = () = /$ENV{PATCHED_RE}/g; print $c' "$TARGET_FILE")

    if [[ "$P_CNT" -eq 1 && "$U_CNT" -eq 0 ]]; then
        PATCH_STATUS="已生效"
    elif [[ "$U_CNT" -eq 1 && "$P_CNT" -eq 0 ]]; then
        PATCH_STATUS="未生效 (当前为官方原版)"
    else
        PATCH_STATUS="未知 (上游代码结构可能已变更)"
    fi

    if [[ -f "${TARGET_FILE}.gz" ]]; then
        CACHE_STATUS="异常 (存在 proxmoxlib.js.gz，可能干扰浏览器加载)"
    else
        CACHE_STATUS="正常"
    fi

    if [[ -f "$PAUSE_FLAG" ]]; then
        HOOK_STATUS="已暂停 (处于容灾还原状态，执行 -e 可重新激活)"
    elif [[ -f "$HOOK_FILE" ]]; then
        HOOK_STATUS="已启用"
    else
        HOOK_STATUS="未启用"
    fi

    if systemctl is-active --quiet pveproxy.service; then
        SVC_STATUS="运行中"
    else
        SVC_STATUS="异常 (未运行)"
    fi

    LATEST_BAK=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'proxmoxlib.js.*.bak' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n 1 | cut -d' ' -f2- || true)

    echo "补丁状态 : $PATCH_STATUS"
    echo "静态缓存 : $CACHE_STATUS"
    echo "自动钩子 : $HOOK_STATUS"
    echo "Web 服务 : $SVC_STATUS (pveproxy)"
    echo "当前备份 : ${LATEST_BAK:-无}"
    echo "可用参数 : -e 执行修补 | --hook 启用钩子 | --unhook 移除钩子 | --restore 容灾还原"
    exit 0
fi

# 涉及系统变更的操作统一加排他锁
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_msg "WARN" "已有实例在运行，跳过本次操作。"
    finish 0
fi

# ==================== 模式 2：启用 APT 自动钩子 (--hook) ====================
if [[ "$MODE" == "hook" ]]; then
    SCRIPT_PATH=$(realpath "$0")
    chown root:root "$SCRIPT_PATH"
    chmod 700 "$SCRIPT_PATH"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    rm -f "$PAUSE_FLAG"

    cat << HOOK_EOF > "$HOOK_FILE"
DPkg::Post-Invoke { "${SCRIPT_PATH} --auto"; };
HOOK_EOF
    chmod 644 "$HOOK_FILE"

    log_msg "INFO" "已启用 APT 自动钩子 ($HOOK_FILE -> $SCRIPT_PATH)。"
    exit 0
fi

# ==================== 模式 3：移除 APT 自动钩子 (--unhook) ====================
if [[ "$MODE" == "unhook" ]]; then
    if [[ -f "$HOOK_FILE" ]]; then
        rm -f "$HOOK_FILE"
        log_msg "INFO" "已移除 APT 自动钩子 ($HOOK_FILE)。"
    else
        log_msg "INFO" "APT 自动钩子未配置，无需移除。"
    fi
    exit 0
fi

# ==================== 模式 4：容灾还原 (--restore) ====================
if [[ "$MODE" == "restore" ]]; then
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    touch "$PAUSE_FLAG"

    LATEST_BAK=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'proxmoxlib.js.*.bak' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n 1 | cut -d' ' -f2- || true)

    RESTORED=false
    if [[ -n "$LATEST_BAK" && -s "$LATEST_BAK" ]]; then
        BAK_U_CNT=$(perl -0777 -ne '$c = () = /$ENV{UNPATCHED_RE}/g; print $c' "$LATEST_BAK")
        if [[ "$BAK_U_CNT" -eq 1 ]]; then
            TMP_FILE=$(mktemp "${TARGET_FILE}.rb.XXXXXX")
            cp -p "$LATEST_BAK" "$TMP_FILE"
            chown --reference="$TARGET_FILE" "$TMP_FILE"
            chmod --reference="$TARGET_FILE" "$TMP_FILE"
            mv -f "$TMP_FILE" "$TARGET_FILE"
            TMP_FILE=""
            log_msg "INFO" "已从备份还原原版文件: $LATEST_BAK"
            RESTORED=true
        else
            log_msg "WARN" "本地备份校验不通过，将通过重装软件包恢复。"
        fi
    fi

    if [[ "$RESTORED" == "false" ]]; then
        log_msg "INFO" "正在重装 proxmox-widget-toolkit 恢复官方原版..."
        apt-get install --reinstall -y proxmox-widget-toolkit >/dev/null
        log_msg "INFO" "已通过官方软件包恢复原版文件。"
    fi

    systemctl reload-or-restart pveproxy.service
    sleep 1
    if systemctl is-active --quiet pveproxy.service; then
        log_msg "INFO" "还原完成，pveproxy 服务运行正常（已暂停 APT 自动钩子）。"
        exit 0
    else
        log_msg "ERROR" "文件已还原，但 pveproxy 服务异常，请检查 systemctl status pveproxy.service。"
        exit 1
    fi
fi

# ==================== 模式 5：执行修补 (-e / --auto) ====================
if [[ "$HOOK_MODE" == "true" && -f "$PAUSE_FLAG" ]]; then
    log_msg "INFO" "处于容灾暂停状态，跳过自动修补。"
    exit 0
fi

if [[ "$HOOK_MODE" == "false" && -f "$PAUSE_FLAG" ]]; then
    rm -f "$PAUSE_FLAG"
fi

if ! command -v perl >/dev/null 2>&1; then
    log_msg "ERROR" "缺少 perl 环境，无法执行修补。"
    finish 1
fi

if [[ ! -s "$TARGET_FILE" ]]; then
    log_msg "ERROR" "目标文件不存在或为空: $TARGET_FILE"
    finish 1
fi

if [[ -f "${TARGET_FILE}.gz" ]]; then
    log_msg "WARN" "检测到 ${TARGET_FILE}.gz，可能干扰浏览器加载新脚本。"
fi

UNPATCHED_COUNT=$(perl -0777 -ne '$c = () = /$ENV{UNPATCHED_RE}/g; print $c' "$TARGET_FILE")
PATCHED_COUNT=$(perl -0777 -ne '$c = () = /$ENV{PATCHED_RE}/g; print $c' "$TARGET_FILE")

if [[ ! "$UNPATCHED_COUNT" =~ ^[0-9]+$ ]] || [[ ! "$PATCHED_COUNT" =~ ^[0-9]+$ ]]; then
    log_msg "ERROR" "目标文件特征解析失败。"
    finish 1
fi

if [[ "$UNPATCHED_COUNT" -eq 0 ]]; then
    if [[ "$PATCHED_COUNT" -eq 1 ]]; then
        log_msg "INFO" "弹窗补丁已生效，无需重复操作。"
        finish 0
    else
        log_msg "WARN" "未匹配到预期弹窗代码，可能 PVE 已改版，已跳过修改。"
        finish 0
    fi
fi

if [[ "$UNPATCHED_COUNT" -ne 1 ]]; then
    log_msg "ERROR" "匹配到 ${UNPATCHED_COUNT} 处弹窗特征（预期 1 处），为防误改已中止。"
    finish 1
fi

# 创建当前版本唯一备份，校验通过后清理历史旧备份
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/proxmoxlib.js.${TIMESTAMP}.bak"
cp -p "$TARGET_FILE" "$BACKUP_FILE"

if [[ ! -s "$BACKUP_FILE" ]]; then
    rm -f "$BACKUP_FILE"
    log_msg "ERROR" "创建备份失败，已中止修改。"
    finish 1
fi

find "$BACKUP_DIR" -maxdepth 1 -type f -name 'proxmoxlib.js.*.bak' ! -name "$(basename "$BACKUP_FILE")" -delete

# 生成临时修补文件并校验
TMP_FILE=$(mktemp "${TARGET_FILE}.tmp.XXXXXX")
if ! perl -0777 -pe 's/$ENV{UNPATCHED_RE}/false/g' "$TARGET_FILE" > "$TMP_FILE"; then
    rm -f "$BACKUP_FILE"
    log_msg "ERROR" "生成修补文件失败，原文件未改动。"
    finish 1
fi

POST_UNPATCHED=$(perl -0777 -ne '$c = () = /$ENV{UNPATCHED_RE}/g; print $c' "$TMP_FILE")
POST_PATCHED=$(perl -0777 -ne '$c = () = /$ENV{PATCHED_RE}/g; print $c' "$TMP_FILE")

if [[ ! -s "$TMP_FILE" ]] || [[ "$POST_UNPATCHED" -ne 0 ]] || [[ "$POST_PATCHED" -ne 1 ]]; then
    rm -f "$BACKUP_FILE"
    log_msg "ERROR" "修补校验未通过，原文件未改动。"
    finish 1
fi

# 原子替换原文件
chown --reference="$TARGET_FILE" "$TMP_FILE"
chmod --reference="$TARGET_FILE" "$TMP_FILE"
mv -f "$TMP_FILE" "$TARGET_FILE"
TMP_FILE=""

rollback_on_reload_fail() {
    log_msg "ERROR" "pveproxy 重载失败，正在自动回滚: $BACKUP_FILE"
    local rb_tmp
    rb_tmp=$(mktemp "${TARGET_FILE}.rb.XXXXXX")
    cp -p "$BACKUP_FILE" "$rb_tmp"
    chown --reference="$TARGET_FILE" "$rb_tmp"
    chmod --reference="$TARGET_FILE" "$rb_tmp"
    mv -f "$rb_tmp" "$TARGET_FILE"
    rm -f "$BACKUP_FILE"
    systemctl reload-or-restart pveproxy.service || true
}

if ! systemctl reload-or-restart pveproxy.service; then
    rollback_on_reload_fail
    finish 1
fi

sleep 1
if ! systemctl is-active --quiet pveproxy.service; then
    rollback_on_reload_fail
    finish 1
fi

log_msg "INFO" "弹窗屏蔽已生效，pveproxy 服务已平滑重载（备份: $BACKUP_FILE）。"
finish 0
