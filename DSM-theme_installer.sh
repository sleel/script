#!/bin/bash
# ==========================================
# DSM 7.4+ 登录页自适应主题安装器
# ==========================================

set -o pipefail

# ---------- 基础校验 ----------
if [ "$(id -u)" -ne 0 ]; then
echo "❌ 请使用 root 权限运行本脚本 (例如: sudo $0)"
exit 1
fi

PERSISTENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSISTENT_CSS="${PERSISTENT_DIR}/custom_theme.css"

WEBMAN_LOGIN_DIR="/usr/syno/synoman/webman/login"
TARGET_CSS="${WEBMAN_LOGIN_DIR}/custom_theme.css"
LOGIN_JS="${WEBMAN_LOGIN_DIR}/dist/dsm.login.bundle.js"

# 唯一标记，避免用通用字符串误判是否已注入
INJECT_MARK="__CUSTOM_THEME_V10_MARK__"
INJECT_JS=";/*${INJECT_MARK}*/var _dsmlink=document.createElement('link');_dsmlink.rel='stylesheet';_dsmlink.type='text/css';_dsmlink.href='/webman/login/custom_theme.css?v=10.0';document.head.appendChild(_dsmlink);"

if [ ! -d "$WEBMAN_LOGIN_DIR" ]; then
echo "❌ 致命错误：未找到 DSM 登录页目录 ($WEBMAN_LOGIN_DIR)，请确认系统版本或路径是否正确"
exit 1
fi

if [ ! -f "$LOGIN_JS" ]; then
echo "❌ 致命错误：无法找到 DSM 登录页入口文件 ($LOGIN_JS)"
exit 1
fi

if [ ! -w "$PERSISTENT_DIR" ]; then
echo "❌ 致命错误：脚本所在目录不可写 ($PERSISTENT_DIR)，无法生成主题缓存文件"
exit 1
fi

# ================= CSS 主题生成引擎 =================

generate_light_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 1. 经典浅色毛玻璃 */
.tab-panel {width:370px;backdrop-filter:blur(12px);background-color:rgba(255,255,255,0.45);box-shadow:0 10px 20px 0 rgba(0,0,0,0.15)}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#172b4d;background-color:transparent}
.login-textfield .bottom-border {background:#fff}
.login-textfield:hover .bottom-border {background:#057FEB}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#172b4d !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#414b55}
EOF
}

generate_dark_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 2. 经典深色半透明 */
.tab-panel {width:370px;backdrop-filter:blur(12px);background-color:rgba(30,30,30,0.55);box-shadow:0 10px 20px 0 rgba(0,0,0,0.5)}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#dedede;background-color:transparent}
.login-textfield .bottom-border {background:rgba(255,255,255,0.3)}
.login-textfield:hover .bottom-border {background:#dedede}
.login-title span, .tab-panel-title, .username-wrapper .back-btn-wrapper .username {color:#f1f1f1}
.login-checkbox .label {color:rgba(222,222,222,0.8)}
#plugin-list>.plugin-cell>.plugin-wrapper>.plugin-desc {color:#ffffff}
.tab-footer-link-ct .tab-footer-link, .footer-link-ct[data-v-7ac5b306] {color:rgba(255,255,255,0.6)}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#dedede !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .title, .syno-securesignin .auth-login-panel .desc, .syno-securesignin .v-checkbox-wrapper .v-checkbox-label {color:#ffffff}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#f1f1f1}
.footer-link-ct span {color:#efefef}
.footer-link-ct a {color:#51d2ff}
EOF
}

generate_macos_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 3. macOS 高透毛玻璃风格 */
.tab-panel {width:370px;backdrop-filter:blur(24px) saturate(180%);background-color:rgba(255,255,255,0.25);box-shadow:0 8px 32px 0 rgba(31,38,135,0.15);border:1px solid rgba(255,255,255,0.4);border-radius:16px}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#2c3e50;background-color:transparent}
.login-textfield .bottom-border {background:rgba(255,255,255,0.6)}
.login-textfield:hover .bottom-border {background:#007aff}
.login-title span {color:#007aff}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#2c3e50 !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#2c3e50}
EOF
}

generate_win11_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 4. Win11 Mica 亚克力风格 */
.tab-panel {width:370px;backdrop-filter:blur(30px);background-color:rgba(32,32,32,0.65);box-shadow:0 8px 16px rgba(0,0,0,0.3);border:1px solid rgba(255,255,255,0.08);border-radius:8px}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#eaeaea;background-color:transparent}
.login-textfield .bottom-border {background:rgba(255,255,255,0.2)}
.login-textfield:hover .bottom-border {background:#4cc2ff}
.login-title span, .tab-panel-title, .username-wrapper .back-btn-wrapper .username {color:#ffffff}
.login-checkbox .label {color:rgba(255,255,255,0.7)}
#plugin-list>.plugin-cell>.plugin-wrapper>.plugin-desc {color:#eaeaea}
.tab-footer-link-ct .tab-footer-link, .footer-link-ct[data-v-7ac5b306] {color:rgba(255,255,255,0.5)}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#eaeaea !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .title, .syno-securesignin .auth-login-panel .desc, .syno-securesignin .v-checkbox-wrapper .v-checkbox-label {color:#ffffff}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#eaeaea}
.footer-link-ct span {color:#cccccc}
.footer-link-ct a {color:#4cc2ff}
EOF
}

generate_nordic_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 5. 北欧极简风 (高透调优版) */
.tab-panel {width:370px;backdrop-filter:blur(24px);background-color:rgba(250,250,250,0.25);box-shadow:none;border:none;border-radius:24px}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#5A6B7C;background-color:transparent;font-weight: 500}
.login-textfield .bottom-border {background:rgba(90,107,124,0.15);height: 1px}
.login-textfield:hover .bottom-border {background:#5A6B7C;height: 2px}
.login-title span, .tab-panel-title, .username-wrapper .back-btn-wrapper .username {color:#333E49}
.login-checkbox .label {color:#7A8B9C}
.tab-footer-link-ct .tab-footer-link, .footer-link-ct[data-v-7ac5b306] {color:#7A8B9C}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#5A6B7C !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .title, .syno-securesignin .auth-login-panel .desc, .syno-securesignin .v-checkbox-wrapper .v-checkbox-label {color:#333E49}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#5A6B7C}
.footer-link-ct span {color:#7A8B9C}
.footer-link-ct a {color:#333E49; font-weight:bold}
EOF
}

generate_aurora_css() {
cat << 'EOF' > "$PERSISTENT_CSS"
@charset "UTF-8";
/* 6. 极光渐变 (Aurora Gradient) - 动态流光毛玻璃 */
.tab-panel {width:370px;border-radius:20px;backdrop-filter:blur(20px) saturate(160%);background:linear-gradient(135deg,rgba(102,126,234,0.28),rgba(118,75,162,0.26),rgba(237,100,166,0.22));background-size:220% 220%;animation:auroraShift 10s ease infinite;box-shadow:0 8px 32px rgba(102,126,234,0.25);border:1px solid rgba(255,255,255,0.25)}
@keyframes auroraShift {0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}
.login-tabs.spinning .login-tabs-content-mask-wrapper:before {background-color:transparent}
.login-textfield .input-container input {color:#2d2d3d;background-color:transparent}
.login-textfield .bottom-border {background:rgba(255,255,255,0.5)}
.login-textfield:hover .bottom-border {background:#7c4dff}
.login-title span, .tab-panel-title, .username-wrapper .back-btn-wrapper .username {color:#2d2d3d}
.login-checkbox .label {color:rgba(45,45,61,0.75)}
.login-textfield .input-container input:-webkit-autofill {-webkit-text-fill-color:#2d2d3d !important;-webkit-box-shadow:0 0 0px 1000px transparent inset !important;background-color:transparent;transition:background-color 50000s ease-in-out 0s}
.syno-securesignin .auth-login-panel .title, .syno-securesignin .auth-login-panel .desc {color:#2d2d3d}
.syno-securesignin .auth-login-panel .verify-number {background:transparent;color:#2d2d3d}
.footer-link-ct span {color:rgba(45,45,61,0.7)}
.footer-link-ct a {color:#7c4dff;font-weight:600}
EOF
}

# ================= 核心注入逻辑 =================

apply_theme() {
if ! cp -f "$PERSISTENT_CSS" "$TARGET_CSS"; then
echo "❌ CSS 文件拷贝失败，请检查磁盘空间及权限"
exit 1
fi
chmod 644 "$TARGET_CSS" || echo "⚠️ 警告：chmod 失败，权限可能不正确"

if grep -qF "$INJECT_MARK" "$LOGIN_JS"; then
echo "✅ 主题样式已无缝刷新！"
echo "💡 提示: 由于启用了极速缓存，请务必按 【Ctrl + F5】 强制刷新浏览器查看最新效果！"
return
fi

echo "⚙️ 首次应用新结构，正在构建底层防御备份..."

# 关键修复：DSM 更新后 login bundle 会被官方替换成新版本，但 .bak 仍是旧版残留。
# 标记不存在(即将执行首次注入)时，当前 LOGIN_JS 必然是"干净"的官方文件，
# 若它与已有 .bak 内容不一致，说明 DSM 已经更新过，必须刷新备份，
# 否则日后卸载会把过期的旧版 bundle 覆盖回当前系统，导致登录页 JS 与 DSM 版本不匹配。
if [ -f "${LOGIN_JS}.bak" ] && ! cmp -s "$LOGIN_JS" "${LOGIN_JS}.bak"; then
echo "ℹ️ 检测到 DSM 登录页文件已更新，刷新备份基线..."
if ! cp -p "$LOGIN_JS" "${LOGIN_JS}.bak"; then
echo "❌ 刷新备份失败，为安全起见已中止注入"
exit 1
fi
elif [ ! -f "${LOGIN_JS}.bak" ]; then
if ! cp -p "$LOGIN_JS" "${LOGIN_JS}.bak"; then
echo "❌ 备份原始 JS 文件失败，为安全起见已中止注入"
exit 1
fi
fi

if [ -f "${LOGIN_JS}.gz" ]; then
if [ ! -f "${LOGIN_JS}.gz.bak" ] || ! cmp -s "${LOGIN_JS}.gz" "${LOGIN_JS}.gz.bak"; then
cp -p "${LOGIN_JS}.gz" "${LOGIN_JS}.gz.bak" || echo "⚠️ 警告：gz 备份失败"
fi
fi

if ! echo -n "$INJECT_JS" >> "$LOGIN_JS"; then
echo "❌ 写入注入代码失败，正在尝试自动回滚..."
cp -pf "${LOGIN_JS}.bak" "$LOGIN_JS" 2>/dev/null
exit 1
fi

if [ -f "${LOGIN_JS}.gz.bak" ]; then
OWNER=$(stat -c "%U:%G" "${LOGIN_JS}.gz.bak")
PERM=$(stat -c "%a" "${LOGIN_JS}.gz.bak")
if gzip -cn "$LOGIN_JS" > "${LOGIN_JS}.gz"; then
chown "$OWNER" "${LOGIN_JS}.gz" 2>/dev/null
chmod "$PERM" "${LOGIN_JS}.gz" 2>/dev/null
else
echo "⚠️ 警告：gzip 重新压缩失败，浏览器可能仍加载旧版预压缩文件"
fi
else
echo "ℹ️ 未检测到预压缩 .gz 文件，跳过 gzip 重建（当前环境可能未启用预压缩）"
fi

echo "🎉 前端极速缓存版劫持成功！请在浏览器中按 Ctrl+F5 强制刷新查看效果。"
}

# ================= 安全回滚逻辑 =================

uninstall_theme() {
echo "🔄 正在执行安全物理回滚..."
if [ -f "${LOGIN_JS}.bak" ]; then
cp -pf "${LOGIN_JS}.bak" "$LOGIN_JS" && rm -f "${LOGIN_JS}.bak"
else
echo "ℹ️ 未发现 JS 备份，跳过 JS 还原"
fi

# 关键修复：只有当 .gz 原本就存在时才重建，否则会在从未启用预压缩的环境里
# "凭空"造出一个系统本不该有的 .gz 文件，违背"无损恢复出厂"的承诺
if [ -f "${LOGIN_JS}.gz.bak" ]; then
cp -pf "${LOGIN_JS}.gz.bak" "${LOGIN_JS}.gz" && rm -f "${LOGIN_JS}.gz.bak"
elif [ -f "${LOGIN_JS}.gz" ]; then
OWNER=$(stat -c "%U:%G" "${LOGIN_JS}")
gzip -cn "$LOGIN_JS" > "${LOGIN_JS}.gz" && chown "$OWNER" "${LOGIN_JS}.gz"
fi

if [ -f "$TARGET_CSS" ]; then
rm -f "$TARGET_CSS"
fi
echo "✅ 系统已完全、无损恢复为出厂默认状态！记得按 Ctrl+F5 刷新。"
}

# ================= 终端交互面板 =================

run_choice() {
case "$1" in
1) generate_light_css && apply_theme ;;
2) generate_dark_css && apply_theme ;;
3) generate_macos_css && apply_theme ;;
4) generate_win11_css && apply_theme ;;
5) generate_nordic_css && apply_theme ;;
6) generate_aurora_css && apply_theme ;;
9) uninstall_theme ;;
q|Q) echo "👋 退出程序"; exit 0 ;;
*) echo "⚠️ 无效选项！"; exit 1 ;;
esac
}

# 支持命令行参数直接调用，便于自动化: ./script.sh 3
if [ -n "$1" ]; then
run_choice "$1"
exit 0
fi

clear
echo "=========================================="
echo " DSM 7.4+ Login Theme Universal "
echo "=========================================="
echo " 1. 【经典】浅色毛玻璃"
echo " 2. 【经典】深色半透明"
echo " 3. 【新潮】macOS 高透滤镜风格"
echo " 4. 【新潮】Win11 Mica 亚克力风格"
echo " 5. 【定制】北欧极简风 (高透调优版)"
echo " 6. 【新增】极光渐变 Aurora (动态流光)"
echo " 9. 卸载主题 (纯净无损还原)"
echo " q. 退出"
echo "=========================================="
read -p "请选择你喜欢的主题 [1-6/9/q]: " choice
run_choice "$choice"
