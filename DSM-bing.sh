#!/bin/sh
# 设置你的语言 (en-US, zh-CN...)
lang="zh-CN"

# 如需收集保存壁纸，去掉下面注释并设置保存路径 (FileStation 文件夹属性可查看)
#savepath="/volume1/myshare/wallpaper"

# res=4k  下载4K分辨率
# res=raw 下载体积更大的原始分辨率图片
#res=4k

# 修改用户桌面壁纸（替换系统 wallpaper1），仅在 DSM7.x 测试过
#desktop=yes

set -u

log() { echo "[x]$1"; }
die() { echo "[!]$1" >&2; exit 1; }

log "Collecting information..."
pic_url="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1"
if [ -n "${res:-}" ]; then
    pic_url="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&uhd=1&uhdwidth=3840&uhdheight=2160"
fi

pic=$(wget -t 5 --no-check-certificate -qO- "$pic_url" --header="cookie:_EDGE_S=mkt=$lang")
[ -n "$pic" ] || die "Empty response from Bing, network issue?"
echo "$pic" | grep -q startdate || die "Unexpected response format, aborting."

link=$(echo "https://www.bing.com$(echo "$pic" | sed 's/.\+"url"[:" ]\+//g' | sed 's/".\+//g')")
if [ "${res:-}" = "raw" ]; then
    raw_link=$(echo "$link" | grep -Eo "https://[-=?/._a-zA-Z0-9]+")
    [ -n "$raw_link" ] && link="$raw_link"
fi
[ -n "$link" ] || die "Failed to parse image link."

date=$(echo "$pic" | grep -Eo '"startdate":"[0-9]+' | grep -Eo '[0-9]+' | head -1)
[ -n "$date" ] || date=$(date +%Y%m%d)

# title / copyright 完整保留原始文本(含括号、逗号、©等符号)，仅去除引号和换行以保证写入config安全
title=$(echo "$pic" | sed 's/.\+"title":"//g' | sed 's/".\+//g' | tr -d "\"'" | tr -d '\n\r')
copyright=$(echo "$pic" | sed 's/.\+"copyright[:" ]\+//g' | sed 's/".\+//g' | tr -d "\"'" | tr -d '\n\r')

# 仅处理 copyright 为空字符串的边界情况(sed会带出JSON里的孤立逗号)，不改变正常文本内容
copyright=$(echo "$copyright" | sed 's/^[,[:space:]]*//;s/[,[:space:]]*$//')

# keyword 仅用于拼文件名，用黑名单排除文件系统不安全字符及逗号，兼容中文等非ASCII字符
keyword=$(echo "$copyright" | sed 's/, /-/g' | cut -d" " -f1 | grep -Eo '[^()\\/:*?"<>,]+' | head -1)
[ -n "$keyword" ] || keyword="unknown"
filename="bing_${date}_${keyword}.jpg"

echo "Link:$link"
echo "Date:$date"
echo "Title:$title"
echo "Copyright:$copyright"
echo "Keyword:$keyword"
echo "Filename:$filename"

log "Downloading wallpaper..."
tmpfile="/tmp/$filename"
wget -t 5 --no-check-certificate "$link" -qO "$tmpfile"

if [ ! -s "$tmpfile" ]; then
    rm -f "$tmpfile"
    die "Download failed or file empty: $tmpfile"
fi
ls -lah "$tmpfile"

log "Copying wallpaper..."
if [ -n "${savepath:-}" ]; then
    if [ -d "$savepath" ]; then
        cp "$tmpfile" "$savepath/"
        chmod 777 "$savepath/$filename"
        echo "Save:$savepath"
        ls -lah "$savepath" | grep "$date"
    else
        echo "[!]savepath '$savepath' does not exist, skip copy."
    fi
else
    echo "savepath is not set, skip copy."
fi

log "Setting welcome msg..."
CONF="/etc/synoinfo.conf"
if [ -f "$CONF" ] && [ ! -f "${CONF}.bak" ]; then
    cp -a "$CONF" "${CONF}.bak"  # 首次运行时备份原始配置
fi

if [ -n "$title" ]; then
    sed -i '/^login_welcome_title=/d' "$CONF"
    echo "login_welcome_title=\"$title\"" >> "$CONF"
fi

if [ -n "$copyright" ]; then
    sed -i '/^login_welcome_msg=/d' "$CONF"
    echo "login_welcome_msg=\"$copyright\"" >> "$CONF"
fi

log "Applying login wallpaper..."
sed -i '/^login_background_customize=/d' "$CONF"
echo 'login_background_customize="yes"' >> "$CONF"

sed -i '/^login_background_type=/d' "$CONF"
echo 'login_background_type="fromDS"' >> "$CONF"

rm -f /usr/syno/etc/login_background*.jpg
cp -f "$tmpfile" /usr/syno/etc/login_background.jpg
ln -sf /usr/syno/etc/login_background.jpg /usr/syno/etc/login_background_hd.jpg

if [ "${desktop:-}" = "yes" ]; then
    log "Applying user desktop wallpaper..."
    mkdir -p /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/
    mkdir -p /usr/syno/synoman/webman/resources/images/1x/default_wallpaper/
    mkdir -p /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/
    mkdir -p /usr/syno/synoman/webman/resources/images/default_wallpaper/

    # DSM 7.0
    cp -f /usr/syno/etc/login_background.jpg /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/1x/default_wallpaper/dsm7_01.jpg
    # DSM 6.0
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/default_wallpaper.jpg
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_01.jpg
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default/1x/default_wallpaper/dsm6_02.jpg
    # DSM 5.2
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/default_wallpaper.jpg
    # DSM 5.1
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/01.jpg
    ln -sf /usr/syno/synoman/webman/resources/images/2x/default_wallpaper/dsm7_01.jpg /usr/syno/synoman/webman/resources/images/default_wallpaper/02.jpg
fi

log "Clean..."
rm -f "$tmpfile"

log "Done."
