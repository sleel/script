#!/bin/bash

SEARCH_DIR="/volumeUSB1"
TARGET_NAME="@eaDir"

# 初始化统计变量
total_freed_kb=0
deleted_count=0
deleted_list=""

echo "🔍 开始深度扫描 $SEARCH_DIR 下的 $TARGET_NAME 目录..."
echo "---------------------------------------------------"

# 核心修复点：使用 9< 和 -u 9，将 find 的输出绑定到专用通道 9，把键盘输入还给 read 交互
while IFS= read -u 9 -r -d '' dir; do
    # 获取该目录的人类可读大小 (如 70G, 500M)
    size_human=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    # 获取纯数字 KB 大小，用于最后计算总空间
    size_kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')

    echo -e "📁 发现目标: \033[33m$dir\033[0m"
    echo -e "📊 占用空间: \033[32m$size_human\033[0m"

    # 现在这里会老老实实等待你的键盘输入了
    read -p "❓ 是否删除该目录? [y/N]: " choice
    case "$choice" in 
        y|Y|yes|Yes )
            rm -rf "$dir"
            if [ $? -eq 0 ]; then
                echo -e "✅ 已删除\n"
                total_freed_kb=$((total_freed_kb + size_kb))
                deleted_count=$((deleted_count + 1))
                deleted_list="$deleted_list- $dir ($size_human)\n"
            else
                echo -e "❌ 删除失败，请检查是否具备 root 权限\n"
            fi
            ;;
        * )
            echo -e "⏭️ 已跳过\n"
            ;;
    esac
done 9< <(find "$SEARCH_DIR" -type d -name "$TARGET_NAME" -print0 2>/dev/null)

echo "==================================================="
echo "📋 清理任务总览:"
if [ "$deleted_count" -eq 0 ]; then
    echo "本次操作没有删除任何目录。"
else
    echo -e "已清理的目录明细:\n$deleted_list"
    
    # 使用 awk 进行纯文本逻辑换算，兼容群晖环境
    total_calc=$(awk -v kb="$total_freed_kb" 'BEGIN {
        if (kb > 1048576) { printf "%.2f GB", kb / 1048576 }
        else if (kb > 1024) { printf "%.2f MB", kb / 1024 }
        else { printf "%d KB", kb }
    }')
    
    echo -e "🎉 大功告成！共计清理了 \033[36m$deleted_count\033[0m 个废弃目录，为您夺回了 \033[36m$total_calc\033[0m 的宝贵空间！"
fi