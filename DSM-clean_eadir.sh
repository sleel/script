#!/bin/bash

# clean_eadir_final.sh —— 默认 dry-run 安全模式，加 -e 才真正执行删除
# 深度扫描并交互式清理 Synology @eaDir 缓存目录

# 用法:
# ./clean_eadir_final.sh # 默认: 扫描 /volumeUSB1，dry-run 预览，不删除
# ./clean_eadir_final.sh -e # 真正执行删除模式，扫描 /volumeUSB1
# ./clean_eadir_final.sh /volume2 # dry-run 预览，扫描 /volume2
# ./clean_eadir_final.sh /volume2 -e # 真正执行删除模式，扫描 /volume2（-e 与路径参数顺序任意）

# 交互选项（仅在 -e 真正执行模式下出现）:
# y/Y -> 删除当前目录
# n/N -> 跳过当前目录（默认）
# a/A -> 本次运行剩余全部删除（不再逐一询问）
# q/Q -> 立即退出脚本

set -uo pipefail

SEARCH_DIR="/volumeUSB1" # 默认目录
TARGET_NAME="@eaDir"
DRY_RUN=true # 默认安全模式：dry-run，只统计不删除
LOG_FILE="/var/log/eadir_cleanup.log"

# 参数解析：-e 开启真正执行删除；其余非选项参数视为搜索路径，顺序任意
for arg in "$@"; do
case "$arg" in
-e|--execute)
DRY_RUN=false
;;
-*)
echo "⚠️ 未知选项: $arg（已忽略）" >&2
;;
*)
SEARCH_DIR="$arg"
;;
esac
done

if [ ! -d "$SEARCH_DIR" ]; then
echo "❌ 路径不存在或未挂载: $SEARCH_DIR" >&2
exit 1
fi

# 若日志目录不可写(常见于非 root 运行)，回退到脚本同目录，避免"详情已记录到日志"
# 这句提示和实际写入结果不一致
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
LOG_FILE="$(cd "$(dirname "$0")" && pwd)/eadir_cleanup.log"
if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
LOG_FILE="/tmp/eadir_cleanup.log"
fi
fi

total_freed_kb=0
found_count=0
declare -a found_list=()
delete_all=false

human_size() {
awk -v kb="$1" 'BEGIN {
if (kb >= 1048576) { printf "%.2f GB", kb/1048576 }
else if (kb >= 1024) { printf "%.2f MB", kb/1024 }
else { printf "%d KB", kb }
}'
}

echo "🔍 开始深度扫描 $SEARCH_DIR 下的 $TARGET_NAME 目录..."
if $DRY_RUN; then
echo "⚠️ 当前为默认 dry-run 预览模式，不会执行任何删除操作（加 -e 参数可真正执行删除）"
else
echo "🔥 当前为真正执行删除模式（-e），请谨慎确认每一步操作"
fi
echo "---------------------------------------------------"

while IFS= read -u 9 -r -d '' dir; do
# du 对含换行的路径会输出多行"大小+路径"，awk 默认逐行打印会把路径片段混进 size_kb，
# 在 set -u 下引发算术表达式崩溃(实测: "xxx: unbound variable")。只取第一行第一列，
# 并强制校验为纯数字，非数字则兜底为 0，扫描不再因单个异常路径而整体中断。
size_kb=$(du -sk "$dir" 2>/dev/null | awk 'NR==1{print $1;exit}')
case "$size_kb" in ''|*[!0-9]*) size_kb=0 ;; esac
size_human=$(human_size "$size_kb")

printf '📁 发现目标: \033[33m%s\033[0m\n' "$dir"
echo -e "📊 占用空间: \033[32m$size_human\033[0m"

if $DRY_RUN; then
echo -e "🔎 dry-run，跳过删除\n"
total_freed_kb=$((total_freed_kb + size_kb))
found_count=$((found_count + 1))
found_list+=("$dir ($size_human)")
continue
fi

if $delete_all; then
choice="y"
else
read -p "❓ 是否删除该目录? [y/N/a=全部删除/q=退出]: " choice
choice="${choice,,}"
fi

if [ "$choice" = "a" ]; then
delete_all=true
choice="y"
fi

case "$choice" in
y|yes)
rm -rf "$dir"
if [ $? -eq 0 ]; then
echo -e "✅ 已删除\n"
total_freed_kb=$((total_freed_kb + size_kb))
found_count=$((found_count + 1))
found_list+=("$dir ($size_human)")
echo "$(date '+%F %T') DELETED $dir ($size_human)" >> "$LOG_FILE" 2>/dev/null
else
echo -e "❌ 删除失败，请检查是否具备 root 权限\n"
fi
;;
q|quit)
echo "🛑 用户中止，提前退出扫描"
break
;;
*)
echo -e "⏭️ 已跳过\n"
;;
esac
done 9< <(find "$SEARCH_DIR" -type d -name "$TARGET_NAME" -print0 2>/dev/null)

echo "==================================================="
echo "📋 清理任务总览:"
if [ "$found_count" -eq 0 ]; then
echo "本次操作没有删除任何目录。"
else
if $DRY_RUN; then
echo "本次扫描发现的目录明细:"
else
echo "已清理的目录明细:"
fi
for item in "${found_list[@]}"; do
echo "- $item"
done

total_calc=$(human_size "$total_freed_kb")

if $DRY_RUN; then
echo -e "🔎 dry-run 结果：共发现 \033[36m$found_count\033[0m 个目录，若加 -e 参数执行删除可释放约 \033[36m$total_calc\033[0m 空间。"
else
echo -e "🎉 大功告成！共计清理了 \033[36m$found_count\033[0m 个废弃目录，为您夺回了 \033[36m$total_calc\033[0m 的宝贵空间！"
echo "📝 详情已记录到日志: $LOG_FILE"
fi
fi
