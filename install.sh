#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# OpenAI-Codex Adapter 一键安装脚本
# 用法: curl -fsSL <URL>/install.sh | bash
#   或: bash install.sh
# ═══════════════════════════════════════════════════════════════════
set -e

INSTALL_DIR="$HOME/.openai-codex-adapter"
PLIST_NAME="com.openai-codex-adapter"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── 预设 Provider ─────────────────────────────────────
declare -A PROVIDER_URLS PROVIDER_MODELS PROVIDER_NAMES
PROVIDER_NAMES=(
  [deepseek]="DeepSeek"
  [xfyun]="讯飞星辰 (Xfyun)"
  [ollama]="Ollama (本地)"
  [lmstudio]="LM Studio (本地)"
  [siliconflow]="SiliconFlow"
  [openai]="OpenAI (官方)"
  [custom]="自定义 (Custom)"
)
PROVIDER_URLS=(
  [deepseek]="https://api.deepseek.com/v1/chat/completions"
  [xfyun]="https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions"
  [ollama]="http://127.0.0.1:11434/v1/chat/completions"
  [lmstudio]="http://127.0.0.1:1234/v1/chat/completions"
  [siliconflow]="https://api.siliconflow.cn/v1/chat/completions"
  [openai]="https://api.openai.com/v1/chat/completions"
  [custom]=""
)
PROVIDER_MODELS=(
  [deepseek]="deepseek-chat"
  [xfyun]="astron-code-latest"
  [ollama]="qwen2.5-coder:7b"
  [lmstudio]="default"
  [siliconflow]="deepseek-ai/DeepSeek-V3"
  [openai]="gpt-4o"
  [custom]=""
)

# ── 检查环境 ──────────────────────────────────────────
info "检查环境..."
[[ "$(uname)" != "Darwin" ]] && die "目前仅支持 macOS，Linux 请参考 README 手动配置 systemd"
PYTHON3="$(command -v python3 || true)"
[[ -z "$PYTHON3" ]] && die "未找到 python3，请先安装: brew install python3"
info "Python: $($PYTHON3 --version 2>&1)"

# ── 选择 Provider ─────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  OpenAI-Codex Adapter 安装向导${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "请选择 API Provider:"
echo ""
i=1
keys=(deepseek xfyun ollama lmstudio siliconflow openai custom)
for k in "${keys[@]}"; do
    echo -e "  ${BOLD}${i})${NC} ${PROVIDER_NAMES[$k]}"
    i=$((i+1))
done
echo ""
echo -ne "请输入编号 [1-${#keys[@]}]: "
read -r choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#keys[@]} ]]; then
    die "无效选择"
fi

SELECTED="${keys[$((choice-1))]}"
SELECTED_NAME="${PROVIDER_NAMES[$SELECTED]}"
UPSTREAM="${PROVIDER_URLS[$SELECTED]}"
DEFAULT_MODEL="${PROVIDER_MODELS[$SELECTED]}"

ok "已选择: $SELECTED_NAME"

# ── 自定义 URL ────────────────────────────────────────
if [[ "$SELECTED" == "custom" ]]; then
    echo ""
    echo -e "请输入 API 地址 (如 https://api.example.com/v1/chat/completions):"
    read -r UPSTREAM
    [[ -z "$UPSTREAM" ]] && die "API 地址不能为空"
fi

# ── 自定义 Model ──────────────────────────────────────
echo ""
if [[ -n "$DEFAULT_MODEL" ]]; then
    echo -ne "模型名称 [默认: $DEFAULT_MODEL]: "
    read -r MODEL
    [[ -z "$MODEL" ]] && MODEL="$DEFAULT_MODEL"
else
    echo -ne "模型名称: "
    read -r MODEL
    [[ -z "$MODEL" ]] && die "模型名称不能为空"
fi

# ── API Key ───────────────────────────────────────────
NEED_KEY=true
if [[ "$SELECTED" == "ollama" || "$SELECTED" == "lmstudio" ]]; then
    NEED_KEY=false
    API_KEY="local-no-key"
fi

if $NEED_KEY; then
    echo ""
    if [[ -n "$ADAPTER_API_KEY" ]]; then
        API_KEY="$ADAPTER_API_KEY"
        info "从环境变量读取 API Key"
    else
        echo -ne "API Key${YELLOW} (输入时不会回显)${NC}: "
        read -rs API_KEY
        echo ""
        [[ -z "$API_KEY" ]] && die "API Key 不能为空"
    fi
fi

# ── 端口 ──────────────────────────────────────────────
PORT="${ADAPTER_PORT:-18666}"
echo ""
echo -ne "适配器端口 [默认: $PORT]: "
read -r input_port
[[ -n "$input_port" ]] && PORT="$input_port"

# ── 重试配置 ──────────────────────────────────────────
RETRY_MAX="${ADAPTER_RETRY_MAX:-5}"
RETRY_DELAY="${ADAPTER_RETRY_DELAY:-2.0}"

# ── 安装文件 ──────────────────────────────────────────
echo ""
info "安装到 $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

# 复制适配器（优先从同目录，否则从网络下载）
if [[ -f "$SCRIPT_DIR/adapter.py" ]]; then
    cp "$SCRIPT_DIR/adapter.py" "$INSTALL_DIR/adapter.py"
elif [[ -f "$(dirname "$0")/adapter.py" ]]; then
    cp "$(dirname "$0")/adapter.py" "$INSTALL_DIR/adapter.py"
else
    info "从 GitHub 下载适配器..."
    curl -fsSL "https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/adapter.py" \
         -o "$INSTALL_DIR/adapter.py" || die "下载失败，请手动下载 adapter.py"
fi
ok "适配器已安装"

# 写配置
cat > "$INSTALL_DIR/config.env" << ENV
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$PORT
ADAPTER_UPSTREAM=$UPSTREAM
ADAPTER_MODEL=$MODEL
ADAPTER_API_KEY=$API_KEY
ADAPTER_RETRY_MAX=$RETRY_MAX
ADAPTER_RETRY_DELAY=$RETRY_DELAY
ENV
ok "配置已写入"

# 写启动脚本
cat > "$INSTALL_DIR/start.sh" << 'STARTEOF'
#!/bin/bash
source "$(dirname "$0")/config.env"
export ADAPTER_HOST ADAPTER_PORT ADAPTER_UPSTREAM ADAPTER_MODEL ADAPTER_API_KEY
export ADAPTER_RETRY_MAX ADAPTER_RETRY_DELAY
exec python3 "$(dirname "$0")/adapter.py"
STARTEOF
chmod +x "$INSTALL_DIR/start.sh"

# 写停止脚本
cat > "$INSTALL_DIR/stop.sh" << 'STOPEOF'
#!/bin/bash
PLIST="$HOME/Library/LaunchAgents/com.openai-codex-adapter.plist"
if [[ -f "$PLIST" ]]; then
    launchctl unload "$PLIST" 2>/dev/null || true
fi
pkill -f "adapter.py" 2>/dev/null || true
echo "✅ 适配器已停止"
STOPEOF
chmod +x "$INSTALL_DIR/stop.sh"

# 写卸载脚本
cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALLEOF'
#!/bin/bash
echo "确定要卸载 OpenAI-Codex Adapter? [y/N]"
read -r confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消" && exit 0
PLIST="$HOME/Library/LaunchAgents/com.openai-codex-adapter.plist"
[[ -f "$PLIST" ]] && launchctl unload "$PLIST" 2>/dev/null && rm -f "$PLIST"
rm -rf "$HOME/.openai-codex-adapter"
echo "✅ 已卸载"
UNINSTALLEOF
chmod +x "$INSTALL_DIR/uninstall.sh"

# 写 Codex 配置脚本
cat > "$INSTALL_DIR/config-codex.sh" << 'CODEXCFGEOF'
#!/bin/bash
CONFIG="$HOME/.codex/config.toml"
source "$(dirname "$0")/config.env"
[[ ! -f "$CONFIG" ]] && echo "未找到 $CONFIG" && exit 1
cp "$CONFIG" "$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
python3 << PY
import re, os
p = os.path.expanduser("~/.codex/config.toml")
with open(p) as f: c = f.read()
env = {}
with open(os.path.expanduser("~/.openai-codex-adapter/config.env")) as f:
    for line in f:
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
port = env.get("ADAPTER_PORT", "18666")
model = env.get("ADAPTER_MODEL", "")
api_key = env.get("ADAPTER_API_KEY", "")
c = re.sub(r'^model_provider\s*=.*', 'model_provider = "custom"', c, flags=re.MULTILINE)
c = re.sub(r'^model\s*=.*', f'model = "{model}"', c, flags=re.MULTILINE)
c = re.sub(r'base_url\s*=.*', f'base_url = "http://127.0.0.1:{port}/v1"', c, flags=re.MULTILINE)
c = re.sub(r'ANTHROPIC_AUTH_TOKEN\s*=.*', f'ANTHROPIC_AUTH_TOKEN = "{api_key}"', c, flags=re.MULTILINE)
with open(p, "w") as f: f.write(c)
print("✅ Codex 配置已更新")
PY
CODEXCFGEOF
chmod +x "$INSTALL_DIR/config-codex.sh"

# ── LaunchAgent ───────────────────────────────────────
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON3</string>
        <string>$INSTALL_DIR/adapter.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ADAPTER_HOST</key>
        <string>127.0.0.1</string>
        <key>ADAPTER_PORT</key>
        <string>$PORT</string>
        <key>ADAPTER_UPSTREAM</key>
        <string>$UPSTREAM</string>
        <key>ADAPTER_MODEL</key>
        <string>$MODEL</string>
        <key>ADAPTER_API_KEY</key>
        <string>$API_KEY</string>
        <key>ADAPTER_RETRY_MAX</key>
        <string>$RETRY_MAX</string>
        <key>ADAPTER_RETRY_DELAY</key>
        <string>$RETRY_DELAY</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$INSTALL_DIR/adapter.log</string>
    <key>StandardErrorPath</key>
    <string>$INSTALL_DIR/adapter.log</string>
</dict>
</plist>
PLIST
ok "开机自启已配置"

# ── 启动 ──────────────────────────────────────────────
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
info "等待服务就绪..."
for i in $(seq 1 15); do
    if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "ok"; then
        ok "服务已就绪 ✓"
        break
    fi
    sleep 1
done

# ── 完成 ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  ✅ 安装完成！${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Provider:  ${CYAN}$SELECTED_NAME${NC}"
echo -e "  上游地址:  ${CYAN}$UPSTREAM${NC}"
echo -e "  模型:      ${CYAN}$MODEL${NC}"
echo -e "  适配器:    ${CYAN}http://127.0.0.1:$PORT${NC}"
echo ""
echo -e "  ${BOLD}Codex 配置${NC} — 在 ${YELLOW}~/.codex/config.toml${NC} 中设置:"
echo ""
echo -e "  ${GREEN}model_provider = \"custom\""
echo -e "  model = \"$MODEL\""
echo -e ""
echo -e "  [model_providers.custom]"
echo -e "  name = \"custom\""
echo -e "  wire_api = \"responses\""
echo -e "  requires_openai_auth = true"
echo -e "  base_url = \"http://127.0.0.1:$PORT/v1\"${NC}"
echo ""
if $NEED_KEY; then
echo -e "  并在 ${YELLOW}[shell_environment_policy.set]${NC} 添加:"
echo -e "  ${GREEN}ANTHROPIC_AUTH_TOKEN = \"你的API Key\"${NC}"
echo ""
fi
echo -e "  或运行自动配置: ${CYAN}bash $INSTALL_DIR/config-codex.sh${NC}"
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo -e "    健康检查: ${CYAN}curl http://127.0.0.1:$PORT/health${NC}"
echo -e "    查看日志: ${CYAN}tail -f $INSTALL_DIR/adapter.log${NC}"
echo -e "    重启服务: ${CYAN}bash $INSTALL_DIR/stop.sh && launchctl load $PLIST_PATH${NC}"
echo -e "    卸载:     ${CYAN}bash $INSTALL_DIR/uninstall.sh${NC}"
echo ""
