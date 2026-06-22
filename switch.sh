#!/bin/bash
# ═══════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — 切换 Provider
# 用法: bash switch.sh
# ═══════════════════════════════════════════════════════════
set -e

INSTALL_DIR="$HOME/.openai-codex-adapter"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openai-codex-adapter.plist"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; BOLD='\033[1m'; YELLOW='\033[1;33m'; NC='\033[0m'

[[ ! -d "$INSTALL_DIR" ]] && echo "❌ 未安装，请先运行 install.sh" && exit 1

# ── 读取当前配置 ──────────────────────────────────────
source "$INSTALL_DIR/config.env"

echo -e "${BOLD}${CYAN}═══ 当前配置 ═══${NC}"
echo -e "  上游地址: ${GREEN}$ADAPTER_UPSTREAM${NC}"
echo -e "  模型:     ${GREEN}$ADAPTER_MODEL${NC}"
echo -e "  端口:     ${GREEN}$ADAPTER_PORT${NC}"
echo ""

# ── 预设 Provider ─────────────────────────────────────
declare -A P_URLS P_MODELS P_NAMES
P_NAMES=(
  [1]="DeepSeek"
  [2]="讯飞星辰 (Xfyun)"
  [3]="Ollama (本地)"
  [4]="LM Studio (本地)"
  [5]="SiliconFlow"
  [6]="OpenAI (官方)"
  [7]="自定义 (Custom)"
  [0]="仅修改 API Key / 模型 / 端口"
)
P_URLS=(
  [1]="https://api.deepseek.com/v1/chat/completions"
  [2]="https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions"
  [3]="http://127.0.0.1:11434/v1/chat/completions"
  [4]="http://127.0.0.1:1234/v1/chat/completions"
  [5]="https://api.siliconflow.cn/v1/chat/completions"
  [6]="https://api.openai.com/v1/chat/completions"
  [7]=""
)
P_MODELS=(
  [1]="deepseek-chat"
  [2]="astron-code-latest"
  [3]="qwen2.5-coder:7b"
  [4]="default"
  [5]="deepseek-ai/DeepSeek-V3"
  [6]="gpt-4o"
  [7]=""
)

echo -e "${BOLD}${CYAN}═══ 选择新的 Provider ═══${NC}"
echo ""
for i in 0 1 2 3 4 5 6 7; do
    echo -e "  ${BOLD}${i})${NC} ${P_NAMES[$i]}"
done
echo ""
echo -ne "请输入编号 [0-7]: "
read -r choice

if ! [[ "$choice" =~ ^[0-7]$ ]]; then
    echo "❌ 无效选择"; exit 1
fi

# ── 收集新配置 ────────────────────────────────────────
NEW_URL="$ADAPTER_UPSTREAM"
NEW_MODEL="$ADAPTER_MODEL"
NEW_KEY="$ADAPTER_API_KEY"
NEW_PORT="$ADAPTER_PORT"

if [[ "$choice" != "0" ]]; then
    # 选了预设或自定义
    if [[ "$choice" == "7" ]]; then
        echo -ne "API 地址: "
        read -r NEW_URL
        [[ -z "$NEW_URL" ]] && echo "❌ 不能为空" && exit 1
    else
        NEW_URL="${P_URLS[$choice]}"
    fi

    DEFAULT_M="${P_MODELS[$choice]}"
    if [[ -n "$DEFAULT_M" ]]; then
        echo -ne "模型名称 [默认: $DEFAULT_M]: "
        read -r input_model
        NEW_MODEL="${input_model:-$DEFAULT_M}"
    else
        echo -ne "模型名称: "
        read -r NEW_MODEL
    fi

    # 本地不需要 key
    if [[ "$choice" == "3" || "$choice" == "4" ]]; then
        NEW_KEY="local-no-key"
    else
        echo -ne "API Key (留空保持不变): "
        read -rs input_key
        echo ""
        [[ -n "$input_key" ]] && NEW_KEY="$input_key"
    fi
else
    # 仅修改部分配置
    echo ""
    echo -ne "新 API 地址 (留空不变): "
    read -r input_url
    [[ -n "$input_url" ]] && NEW_URL="$input_url"

    echo -ne "新模型名称 (留空不变): "
    read -r input_model
    [[ -n "$input_model" ]] && NEW_MODEL="$input_model"

    echo -ne "新 API Key (留空不变): "
    read -rs input_key
    echo ""
    [[ -n "$input_key" ]] && NEW_KEY="$input_key"
fi

echo -ne "端口 [当前: $NEW_PORT, 回车不变]: "
read -r input_port
[[ -n "$input_port" ]] && NEW_PORT="$input_port"

# ── 写入配置 ──────────────────────────────────────────
cat > "$INSTALL_DIR/config.env" << ENV
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$NEW_PORT
ADAPTER_UPSTREAM=$NEW_URL
ADAPTER_MODEL=$NEW_MODEL
ADAPTER_API_KEY=$NEW_KEY
ADAPTER_RETRY_MAX=$ADAPTER_RETRY_MAX
ADAPTER_RETRY_DELAY=$ADAPTER_RETRY_DELAY
ENV

# ── 更新 LaunchAgent ──────────────────────────────────
PYTHON3="$(command -v python3)"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openai-codex-adapter</string>
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
        <string>$NEW_PORT</string>
        <key>ADAPTER_UPSTREAM</key>
        <string>$NEW_URL</string>
        <key>ADAPTER_MODEL</key>
        <string>$NEW_MODEL</string>
        <key>ADAPTER_API_KEY</key>
        <string>$NEW_KEY</string>
        <key>ADAPTER_RETRY_MAX</key>
        <string>$ADAPTER_RETRY_MAX</string>
        <key>ADAPTER_RETRY_DELAY</key>
        <string>$ADAPTER_RETRY_DELAY</string>
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

# ── 重启服务 ──────────────────────────────────────────
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo -e "${GREEN}  ✅ 已切换并重启${NC}"
echo -e "${GREEN}══════════════════════════════════════${NC}"
echo -e "  上游: ${CYAN}$NEW_URL${NC}"
echo -e "  模型: ${CYAN}$NEW_MODEL${NC}"
echo -e "  端口: ${CYAN}$NEW_PORT${NC}"
echo ""
echo -e "${YELLOW}  ⚠️  别忘了同步更新 Codex config.toml 中的 model 和 ANTHROPIC_AUTH_TOKEN${NC}"
echo -e "  或运行: ${CYAN}bash $INSTALL_DIR/config-codex.sh${NC}"
echo ""
