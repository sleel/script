#!/bin/bash
# ==========================================
# DSM 7.4+ 登录页自适应主题安装器 V8 (独立优化版)
# ==========================================

# 1. 精准锚定当前工作目录
PERSISTENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSISTENT_CSS="${PERSISTENT_DIR}/custom_theme.css"

# 2. 系统 Web 目录与目标文件
WEBMAN_LOGIN_DIR="/usr/syno/synoman/webman/login"
TARGET_CSS="${WEBMAN_LOGIN_DIR}/custom_theme.css"
LOGIN_JS="${WEBMAN_LOGIN_DIR}/dist/dsm.login.bundle.js"

# 3. 动态注入的 JS 代码 (固定版本号 v=8.0 触发极致浏览器缓存)
INJECT_JS=";var _dsmlink=document.createElement('link');_dsmlink.rel='stylesheet';_dsmlink.type='text/css';_dsmlink.href='/webman/login/custom_theme.css?v=8.0';document.head.appendChild(_dsmlink);"

if [ ! -f "$LOGIN_JS" ]; then
    echo "❌ 致命错误：无法找到 DSM 登录页入口文件 ($LOGIN_JS)"
    exit 1
fi

# ================= CSS 主题生成引擎 =================
# 注意：首行强制声明 UTF-8，彻底解决中文注释乱码问题

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

# ================= 核心注入逻辑 =================

apply_theme() {
    cp -f "$PERSISTENT_CSS" "$TARGET_CSS"
    chmod 644 "$TARGET_CSS"

    if grep -q "custom_theme.css" "$LOGIN_JS"; then
        echo "✅ 主题样式已无缝刷新！"
        echo "💡 提示: 由于启用了极速缓存，请务必按 【Ctrl + F5】 强制刷新浏览器查看最新效果！"
        return
    fi

    echo "⚙️ 首次应用新结构，正在构建底层防御备份..."
    if [ ! -f "${LOGIN_JS}.bak" ]; then
        cp -p "$LOGIN_JS" "${LOGIN_JS}.bak"
    fi
    if [ -f "${LOGIN_JS}.gz" ] && [ ! -f "${LOGIN_JS}.gz.bak" ]; then
        cp -p "${LOGIN_JS}.gz" "${LOGIN_JS}.gz.bak"
    fi
    
    echo -n "$INJECT_JS" >> "$LOGIN_JS"
    
    if [ -f "${LOGIN_JS}.gz.bak" ]; then
        OWNER=$(stat -c "%U:%G" "${LOGIN_JS}.gz.bak")
        PERM=$(stat -c "%a" "${LOGIN_JS}.gz.bak")
        gzip -c "$LOGIN_JS" > "${LOGIN_JS}.gz"
        chown "$OWNER" "${LOGIN_JS}.gz"
        chmod "$PERM" "${LOGIN_JS}.gz"
    fi
    
    echo "🎉 前端极速缓存版劫持成功！请在浏览器中按 Ctrl+F5 强制刷新查看效果。"
}

# ================= 安全回滚逻辑 =================

uninstall_theme() {
    echo "🔄 正在执行安全物理回滚..."
    if [ -f "${LOGIN_JS}.bak" ]; then
        cp -pf "${LOGIN_JS}.bak" "$LOGIN_JS"
    fi

    if [ -f "${LOGIN_JS}.gz.bak" ]; then
        cp -pf "${LOGIN_JS}.gz.bak" "${LOGIN_JS}.gz"
    elif [ -f "$LOGIN_JS" ]; then
        OWNER=$(stat -c "%U:%G" "${LOGIN_JS}")
        gzip -c "$LOGIN_JS" > "${LOGIN_JS}.gz"
        chown "$OWNER" "${LOGIN_JS}.gz"
    fi
    
    if [ -f "$TARGET_CSS" ]; then
        rm -f "$TARGET_CSS"
    fi
    echo "✅ 系统已完全、无损恢复为出厂默认状态！记得按 Ctrl+F5 刷新。"
}

# ================= 终端交互面板 =================

clear
echo "=========================================="
echo "    DSM 7.4+ Login Theme Universal V8     "
echo "=========================================="
echo " 1. 【经典】浅色毛玻璃"
echo " 2. 【经典】深色半透明"
echo " 3. 【新潮】macOS 高透滤镜风格"
echo " 4. 【新潮】Win11 Mica 亚克力风格"
echo " 5. 【定制】北欧极简风 (高透调优版)"
echo " 6. 卸载主题 (纯净无损还原)"
echo " q. 退出"
echo "=========================================="
read -p "请选择你喜欢的主题 [1-6/q]: " choice

case $choice in
    1) generate_light_css; apply_theme ;;
    2) generate_dark_css; apply_theme ;;
    3) generate_macos_css; apply_theme ;;
    4) generate_win11_css; apply_theme ;;
    5) generate_nordic_css; apply_theme ;;
    6) uninstall_theme ;;
    q|Q) echo "👋 退出程序"; exit 0 ;;
    *) echo "⚠️ 无效选项！" ;;
esac