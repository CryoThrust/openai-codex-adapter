#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — macOS 切换 Provider
# ═══════════════════════════════════════════════════════════
set -euo pipefail

INSTALL_DIR="$HOME/.openai-codex-adapter"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openai-codex-adapter.plist"
CC_SWITCH_DB="$HOME/.cc-switch/cc-switch.db"
PROVIDER_ID="openai-codex-adapter"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; BOLD='\033[1m'; YELLOW='\033[1;33m'; NC='\033[0m'

[[ ! -d "$INSTALL_DIR" ]] && echo "❌ 未安装" && exit 1
source "$INSTALL_DIR/config.env"

echo -e "${BOLD}${CYAN}═══ 当前配置 ═══${NC}"
echo -e "  上游: ${GREEN}$ADAPTER_UPSTREAM${NC}"
echo -e "  模型: ${GREEN}$ADAPTER_MODEL${NC}"
echo -e "  端口: ${GREEN}$ADAPTER_PORT${NC}"
echo -e "  上下文: ${GREEN}${ADAPTER_CONTEXT_WINDOW:-0} tokens (压缩: ${ADAPTER_AUTO_COMPACT_LIMIT:-0})${NC}"
echo ""

# (bash 3.2 兼容: 用函数代替 declare -A 关联数组)

_pname() { case $1 in 0) echo "仅改 Key/模型/端口";; 1) echo "DeepSeek";; 2) echo "讯飞星辰";; 3) echo "Ollama (本地)";; 4) echo "LM Studio (本地)";; 5) echo "SiliconFlow";; 6) echo "OpenAI (官方)";; 7) echo "自定义";; esac; }
_purl()  { case $1 in 1) echo "https://api.deepseek.com/v1/chat/completions";; 2) echo "https://maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions";; 3) echo "http://127.0.0.1:11434/v1/chat/completions";; 4) echo "http://127.0.0.1:1234/v1/chat/completions";; 5) echo "https://api.siliconflow.cn/v1/chat/completions";; 6) echo "https://api.openai.com/v1/chat/completions";; 7) echo "";; esac; }
_pmodel() { case $1 in 1) echo "deepseek-chat";; 2) echo "astron-code-latest";; 3) echo "qwen2.5-coder:7b";; 4) echo "default";; 5) echo "deepseek-ai/DeepSeek-V3";; 6) echo "gpt-4o";; 7) echo "";; esac; }
_pctx()  { case $1 in 1) echo "128000";; 2) echo "200000";; 3) echo "128000";; 4) echo "128000";; 5) echo "128000";; 6) echo "128000";; 7) echo "0";; esac; }

echo -e "${BOLD}${CYAN}═══ 选择新 Provider ═══${NC}"
for i in 0 1 2 3 4 5 6 7; do echo -e "  ${BOLD}${i})${NC} $(_pname $i)"; done
echo ""
echo -ne "请输入编号 [0-7]: "
read -r choice
[[ "$choice" =~ ^[0-7]$ ]] || { echo "❌ 无效"; exit 1; }

NEW_URL="$ADAPTER_UPSTREAM"; NEW_MODEL="$ADAPTER_MODEL"; NEW_KEY="$ADAPTER_API_KEY"; NEW_PORT="$ADAPTER_PORT"

if [[ "$choice" != "0" ]]; then
    if [[ "$choice" == "7" ]]; then
        echo -ne "API 地址: "; read -r NEW_URL; [[ -z "$NEW_URL" ]] && exit 1
    else
        NEW_URL="$(_purl $choice)"
    fi
    DEFAULT_M="$(_pmodel $choice)"
    if [[ -n "$DEFAULT_M" ]]; then
        echo -ne "模型 [默认: $DEFAULT_M]: "; read -r m; NEW_MODEL="${m:-$DEFAULT_M}"
    else
        echo -ne "模型: "; read -r NEW_MODEL
    fi
    if [[ "$choice" == "3" || "$choice" == "4" ]]; then
        NEW_KEY="local-no-key"
    else
        echo -ne "API Key (留空不变): "; stty -echo 2>/dev/null; read -r k; stty echo 2>/dev/null; echo ""; [[ -n "$k" ]] && NEW_KEY="$k"
    fi
else
    echo -ne "新 API 地址 (留空不变): "; read -r u; [[ -n "$u" ]] && NEW_URL="$u"
    echo -ne "新模型 (留空不变): "; read -r m; [[ -n "$m" ]] && NEW_MODEL="$m"
    echo -ne "新 API Key (留空不变): "; stty -echo 2>/dev/null; read -r k; stty echo 2>/dev/null; echo ""; [[ -n "$k" ]] && NEW_KEY="$k"
fi
echo -ne "端口 [当前: $NEW_PORT, 回车不变]: "; read -r p; [[ -n "$p" ]] && NEW_PORT="$p"

# ── 上下文窗口 ────────────────────────────────────
CURRENT_CONTEXT="${ADAPTER_CONTEXT_WINDOW:-0}"
CURRENT_COMPACT="${ADAPTER_AUTO_COMPACT_LIMIT:-0}"
NEW_CONTEXT="$CURRENT_CONTEXT"
NEW_COMPACT="$CURRENT_COMPACT"

if [[ "$choice" != "0" ]]; then
    PRESET_CTX="$(_pctx $choice)"
    if [[ "$PRESET_CTX" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}模型上下文窗口:${NC} ${CYAN}${PRESET_CTX} tokens${NC}"
        echo -ne "  确认或自定义 [回车确认 / 输入数值]: "
        read -r ctx_input
        if [[ -n "$ctx_input" ]]; then
            NEW_CONTEXT="$ctx_input"
        else
            NEW_CONTEXT="$PRESET_CTX"
        fi
    else
        echo ""
        echo -ne "  上下文窗口 (当前: $CURRENT_CONTEXT, 0=不限): "
        read -r ctx_input
        [[ -n "$ctx_input" ]] && NEW_CONTEXT="$ctx_input"
    fi
else
    echo ""
    echo -ne "  上下文窗口 (当前: $CURRENT_CONTEXT, 回车不变): "
    read -r ctx_input
    [[ -n "$ctx_input" ]] && NEW_CONTEXT="$ctx_input"
fi

if [[ "$NEW_CONTEXT" -gt 0 ]]; then
    DEFAULT_COMPACT=$(( NEW_CONTEXT * 80 / 100 ))
    echo -ne "  自动压缩阈值 [当前: $CURRENT_COMPACT, 默认80%=$DEFAULT_COMPACT]: "
    read -r compact_input
    if [[ -n "$compact_input" ]]; then
        NEW_COMPACT="$compact_input"
    elif [[ "$CURRENT_COMPACT" -eq 0 || "$choice" != "0" ]]; then
        NEW_COMPACT="$DEFAULT_COMPACT"
    fi
else
    NEW_COMPACT=0
fi

# 写配置
cat > "$INSTALL_DIR/config.env" << ENV
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$NEW_PORT
ADAPTER_UPSTREAM=$NEW_URL
ADAPTER_MODEL=$NEW_MODEL
ADAPTER_API_KEY=$NEW_KEY
ADAPTER_RETRY_MAX=$ADAPTER_RETRY_MAX
ADAPTER_RETRY_DELAY=$ADAPTER_RETRY_DELAY
ADAPTER_CONTEXT_WINDOW=$NEW_CONTEXT
ADAPTER_AUTO_COMPACT_LIMIT=$NEW_COMPACT
ENV

# 更新 LaunchAgent
PYTHON3="$(command -v python3)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.openai-codex-adapter</string>
    <key>ProgramArguments</key><array><string>${PYTHON3}</string><string>${INSTALL_DIR}/adapter.py</string></array>
    <key>EnvironmentVariables</key><dict>
        <key>ADAPTER_HOST</key><string>127.0.0.1</string>
        <key>ADAPTER_PORT</key><string>${NEW_PORT}</string>
        <key>ADAPTER_UPSTREAM</key><string>${NEW_URL}</string>
        <key>ADAPTER_MODEL</key><string>${NEW_MODEL}</string>
        <key>ADAPTER_API_KEY</key><string>${NEW_KEY}</string>
        <key>ADAPTER_RETRY_MAX</key><string>${ADAPTER_RETRY_MAX}</string>
        <key>ADAPTER_RETRY_DELAY</key><string>${ADAPTER_RETRY_DELAY}</string>
        <key>ADAPTER_CONTEXT_WINDOW</key><string>${NEW_CONTEXT}</string>
        <key>ADAPTER_AUTO_COMPACT_LIMIT</key><string>${NEW_COMPACT}</string>
    </dict>
    <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/adapter.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/adapter.log</string>
</dict>
</plist>
PLIST

# 更新 CC Switch provider
if [[ -f "$CC_SWITCH_DB" ]]; then
    python3 << PYCC
import json, sqlite3
from pathlib import Path
con = sqlite3.connect("$CC_SWITCH_DB")
now = int(__import__('time').time() * 1000)
app_type = "codex"
provider_id = "$PROVIDER_ID"
config = f'''model = "$NEW_MODEL"
model_provider = "openai"
openai_base_url = "http://127.0.0.1:$NEW_PORT/v1"
model_context_window = "$NEW_CONTEXT"
model_auto_compact_token_limit = "$NEW_COMPACT"'''
settings = {"auth": {"OPENAI_API_KEY": "$NEW_KEY"}, "config": config}
meta = {"provider_url": "$NEW_URL", "provider_model": "$NEW_MODEL", "port": "$NEW_PORT"}
con.execute("""insert into providers (
    id, app_type, name, settings_config, website_url, category, created_at, sort_index,
    notes, icon, icon_color, meta, is_current, in_failover_queue, cost_multiplier,
    limit_daily_usd, limit_monthly_usd, provider_type
) values (?,?,?,?,?,?,?,?,?,?,?, ?,0,0,'1.0',NULL,NULL,NULL)
on conflict(id, app_type) do update set
    name=excluded.name, settings_config=excluded.settings_config,
    notes=excluded.notes, meta=excluded.meta""",
    (provider_id, app_type, "OpenAI Codex Adapter",
     json.dumps(settings, ensure_ascii=False, separators=(",",":")),
     "", "third_party", now, 0,
     "Local adapter: Responses API -> Chat Completions. Auto-retry.",
     "custom-icon", "#2563EB", json.dumps(meta, ensure_ascii=False, separators=(",",":"))))
con.execute("delete from provider_endpoints where provider_id=? and app_type=?", (provider_id, app_type))
con.execute("insert into provider_endpoints(provider_id, app_type, url, added_at) values (?,?,?,?)",
            (provider_id, app_type, f"http://127.0.0.1:$NEW_PORT/v1", now))
# write live config — patch existing, never overwrite
codex_dir = Path("$HOME/.codex")
codex_dir.mkdir(parents=True, exist_ok=True)
codex_config = codex_dir / "config.toml"
import re
if codex_config.exists():
    existing = codex_config.read_text(encoding="utf-8")
    existing = re.sub(r"^model\s*=.*", f'model = "$NEW_MODEL"', existing, flags=re.MULTILINE)
    existing = re.sub(r"^model_provider\s*=.*", 'model_provider = "openai"', existing, flags=re.MULTILINE)
    if "openai_base_url" in existing:
        existing = re.sub(r"^openai_base_url\s*=.*", f'openai_base_url = "http://127.0.0.1:$NEW_PORT/v1"', existing, flags=re.MULTILINE)
    else:
        existing = re.sub(r"^(model_provider\s*=.*\n)", f'\\1openai_base_url = "http://127.0.0.1:$NEW_PORT/v1"\n', existing, flags=re.MULTILINE)
    codex_config.write_text(existing, encoding="utf-8")
else:
    codex_config.write_text(config + "\n")
(codex_dir / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "$NEW_KEY"}, ensure_ascii=False, indent=2) + "\n")
con.commit(); con.close()
PYCC
    echo -e "${CYAN}[INFO]${NC} CC Switch 已同步"
fi

# 重启服务
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo -e "${GREEN}✅ 已切换并重启${NC}"
echo -e "  上游: ${CYAN}$NEW_URL${NC}"
echo -e "  模型: ${CYAN}$NEW_MODEL${NC}"
echo -e "  端口: ${CYAN}$NEW_PORT${NC}"
echo -e "  上下文: ${CYAN}${NEW_CONTEXT} tokens (压缩阈值: ${NEW_COMPACT})${NC}"
echo ""
echo -e "${YELLOW}⚠️  请重启 Codex 生效${NC}"
