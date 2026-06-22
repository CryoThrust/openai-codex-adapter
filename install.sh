#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# OpenAI-Codex Adapter — macOS 一键安装
# 用法: curl -fsSL https://gitee.com/kangarooking/openai-codex-adapter/raw/main/install.sh | bash
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

INSTALL_DIR="$HOME/.openai-codex-adapter"
PLIST_LABEL="com.openai-codex-adapter"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
CC_SWITCH_DIR="$HOME/.cc-switch"
CC_SWITCH_DB="$CC_SWITCH_DIR/cc-switch.db"
CODEX_DIR="$HOME/.codex"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
die()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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

# ── 检查环境 ──────────────────────────────────────────
[[ "$(uname -s)" != "Darwin" ]] && die "macOS only. Windows 请使用 install.ps1"
PYTHON3="$(command -v python3 || true)"
[[ -z "$PYTHON3" ]] && die "未找到 python3"

# ── 已安装检测 ────────────────────────────────────────
if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/config.env" ]]; then
    source "$INSTALL_DIR/config.env"
    echo ""
    echo -e "${BOLD}${YELLOW}═══ 检测到已安装 ═══${NC}"
    echo -e "  上游: ${CYAN}$ADAPTER_UPSTREAM${NC}"
    echo -e "  模型: ${CYAN}$ADAPTER_MODEL${NC}"
    echo -e "  端口: ${CYAN}$ADAPTER_PORT${NC}"
    echo -e "  状态: ${CYAN}$(curl -s "http://127.0.0.1:$ADAPTER_PORT/health" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('running' if d.get('ok') else 'stopped')" 2>/dev/null || echo "stopped")${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} 重新配置 (切换 Provider / 修改 API Key)"
    echo -e "  ${BOLD}2)${NC} 卸载"
    echo -e "  ${BOLD}3)${NC} 取消退出"
    echo ""
    echo -ne "请选择 [1-3]: "
    read -r reinstall_choice
    case "$reinstall_choice" in
        1)
            info "重新配置..."
            # 停止当前服务
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            # 继续往下走安装流程（会覆盖 config.env 和 LaunchAgent）
            ;;
        2)
            exec bash "$INSTALL_DIR/uninstall.sh"
            ;;
        *)
            echo "已取消"
            exit 0
            ;;
    esac
fi

# ── 选择 Provider ─────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  OpenAI-Codex Adapter 安装向导${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "请选择 API Provider:"
echo ""
for i in 1 2 3 4 5 6 7; do
    echo -e "  ${BOLD}${i})${NC} ${P_NAMES[$i]}"
done
echo ""
echo -ne "请输入编号 [1-7]: "
read -r choice
[[ "$choice" =~ ^[1-7]$ ]] || die "无效选择"

SELECTED="$choice"
SELECTED_NAME="${P_NAMES[$SELECTED]}"
UPSTREAM="${P_URLS[$SELECTED]}"
DEFAULT_MODEL="${P_MODELS[$SELECTED]}"
ok "已选择: $SELECTED_NAME"

# ── 自定义 URL ────────────────────────────────────────
if [[ "$SELECTED" == "7" ]]; then
    echo ""
    echo -ne "API 地址 (如 https://api.example.com/v1/chat/completions): "
    read -r UPSTREAM
    [[ -z "$UPSTREAM" ]] && die "不能为空"
fi

# ── Model ─────────────────────────────────────────────
echo ""
if [[ -n "$DEFAULT_MODEL" ]]; then
    echo -ne "模型名称 [默认: $DEFAULT_MODEL]: "
    read -r MODEL
    MODEL="${MODEL:-$DEFAULT_MODEL}"
else
    echo -ne "模型名称: "
    read -r MODEL
    [[ -z "$MODEL" ]] && die "不能为空"
fi

# ── API Key ───────────────────────────────────────────
NEED_KEY=true
if [[ "$SELECTED" == "3" || "$SELECTED" == "4" ]]; then
    NEED_KEY=false
    API_KEY="local-no-key"
fi
if $NEED_KEY; then
    echo ""
    echo -ne "API Key${YELLOW} (输入不回显)${NC}: "
    stty -echo 2>/dev/null || true
    read -r API_KEY
    stty echo 2>/dev/null || true
    echo ""
    [[ -z "$API_KEY" ]] && die "不能为空"
fi

# ── 端口 ──────────────────────────────────────────────
PORT="18666"
echo ""
echo -ne "端口 [默认: $PORT]: "
read -r input_port
[[ -n "$input_port" ]] && PORT="$input_port"

# ── 安装文件 ──────────────────────────────────────────
info "安装到 $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

# 下载/复制 adapter.py
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/adapter.py" ]]; then
    cp "$SCRIPT_DIR/adapter.py" "$INSTALL_DIR/adapter.py"
else
    GITEE_URL="https://gitee.com/CryoThrust/openai-codex-adapter/raw/main/adapter.py"
    GH_URL="https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/adapter.py"
    curl -fsSL "$GITEE_URL" -o "$INSTALL_DIR/adapter.py" 2>/dev/null || \
    curl -fsSL "$GH_URL" -o "$INSTALL_DIR/adapter.py" 2>/dev/null || \
    die "下载 adapter.py 失败"
fi
ok "适配器已安装"

# 写配置
cat > "$INSTALL_DIR/config.env" << ENV
ADAPTER_HOST=127.0.0.1
ADAPTER_PORT=$PORT
ADAPTER_UPSTREAM=$UPSTREAM
ADAPTER_MODEL=$MODEL
ADAPTER_API_KEY=$API_KEY
ADAPTER_RETRY_MAX=5
ADAPTER_RETRY_DELAY=2.0
ENV
ok "配置已写入"

# ── LaunchAgent (开机自启 + 崩溃重启) ─────────────────
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3}</string>
        <string>${INSTALL_DIR}/adapter.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>ADAPTER_HOST</key><string>127.0.0.1</string>
        <key>ADAPTER_PORT</key><string>${PORT}</string>
        <key>ADAPTER_UPSTREAM</key><string>${UPSTREAM}</string>
        <key>ADAPTER_MODEL</key><string>${MODEL}</string>
        <key>ADAPTER_API_KEY</key><string>${API_KEY}</string>
        <key>ADAPTER_RETRY_MAX</key><string>5</string>
        <key>ADAPTER_RETRY_DELAY</key><string>2.0</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${INSTALL_DIR}/adapter.log</string>
    <key>StandardErrorPath</key><string>${INSTALL_DIR}/adapter.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
info "等待服务就绪..."
for i in $(seq 1 15); do
    curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "ok" && break
    sleep 1
done
ok "服务已启动"

# ── 自动配置 Codex ────────────────────────────────────
CODEX_CONFIGURED=false
echo ""
echo -ne "${YELLOW}是否自动配置 Codex config.toml？[Y/n]${NC}: "
read -r codex_choice
if [[ "$codex_choice" != "n" && "$codex_choice" != "N" ]]; then
    info "配置 Codex ..."
    python3 << PYCODEX
import json, re
from pathlib import Path

codex_dir = Path("$CODEX_DIR")
config_path = codex_dir / "config.toml"
api_key = "$API_KEY"
model = "$MODEL"
port = "$PORT"
base_url = f"http://127.0.0.1:{port}/v1"

codex_dir.mkdir(parents=True, exist_ok=True)

# Backup existing config
if config_path.exists():
    backup = config_path.with_suffix(f".toml.bak")
    config_path.rename(backup)

# Read existing config if exists (from backup)
existing = ""
if backup.exists():
    existing = backup.read_text(encoding="utf-8")

# If config exists, patch it; otherwise write fresh
if existing:
    # Update model_provider
    existing = re.sub(r"^model_provider\s*=.*", "model_provider = \"custom\"", existing, flags=re.MULTILINE)
    # Update model
    existing = re.sub(r"^model\s*=.*", f"model = \"{model}\"", existing, flags=re.MULTILINE)

    # Find or create [model_providers.custom] section
    if "[model_providers.custom]" not in existing:
        # Find [model_providers] and add custom section after it
        if "[model_providers]" in existing:
            existing = existing.replace(
                "[model_providers]",
                f"[model_providers]\n[model_providers.custom]\nname = \"custom\"\nwire_api = \"responses\"\nrequires_openai_auth = true\nbase_url = \"{base_url}\""
            )
        else:
            existing += f"\n\n[model_providers]\n[model_providers.custom]\nname = \"custom\"\nwire_api = \"responses\"\nrequires_openai_auth = true\nbase_url = \"{base_url}\""
    else:
        existing = re.sub(r"base_url\s*=.*", f"base_url = \"{base_url}\"", existing, flags=re.MULTILINE)
        existing = re.sub(r"wire_api\s*=.*", "wire_api = \"responses\"", existing, flags=re.MULTILINE)

    # Update ANTHROPIC_AUTH_TOKEN in shell_environment_policy.set
    if "ANTHROPIC_AUTH_TOKEN" in existing:
        existing = re.sub(r"ANTHROPIC_AUTH_TOKEN\s*=.*", f"ANTHROPIC_AUTH_TOKEN = \"{api_key}\"", existing, flags=re.MULTILINE)
    else:
        # Add to shell_environment_policy.set section
        if "[shell_environment_policy.set]" in existing:
            existing = existing.replace(
                "[shell_environment_policy.set]",
                f"[shell_environment_policy.set]\nANTHROPIC_AUTH_TOKEN = \"{api_key}\""
            )

    config_path.write_text(existing, encoding="utf-8")
else:
    # Write fresh minimal config
    config = f"""model_provider = "custom"
model = "{model}"

[model_providers]
[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "{base_url}"

[shell_environment_policy]
inherit = "core"

[shell_environment_policy.set]
ANTHROPIC_AUTH_TOKEN = "{api_key}"
"""
    config_path.write_text(config, encoding="utf-8")

print("  Codex config written")
PYCODEX
    CODEX_CONFIGURED=true
    ok "Codex 已配置"
fi

# ── CC Switch 集成 ────────────────────────────────────
CC_INTEGRATED=false
if [[ -f "$CC_SWITCH_DB" ]]; then
    echo ""
    echo -ne "${YELLOW}检测到 CC Switch，是否自动集成？(在 CC Switch 里新增 Provider) [Y/n]${NC}: "
    read -r cc_choice
    if [[ "$cc_choice" != "n" && "$cc_choice" != "N" ]]; then
        info "集成 CC Switch ..."
        PROVIDER_ID="openai-codex-adapter"
        BASE_URL="http://127.0.0.1:${PORT}/v1"
        python3 << PYCC
import json, sqlite3, time
from pathlib import Path

db = Path("$CC_SWITCH_DB")
con = sqlite3.connect(str(db))
now = int(time.time() * 1000)
app_type = "codex"
provider_id = "$PROVIDER_ID"
base_url = "$BASE_URL"
api_key = "$API_KEY"
model = "$MODEL"
port = "$PORT"

config = f'''model = "{model}"
model_provider = "openai_codex_adapter"

[model_providers]
[model_providers.openai_codex_adapter]
name = "OpenAI Codex Adapter"
base_url = "{base_url}"
wire_api = "responses"
requires_openai_auth = true
request_max_retries = 2
stream_max_retries = 2
stream_idle_timeout_ms = 300000'''

settings = {"auth": {"OPENAI_API_KEY": api_key}, "config": config}
meta = {"provider_url": "$UPSTREAM", "provider_model": model, "port": port}

# backfill current provider
local_settings_path = Path("$CC_SWITCH_DIR/settings.json")
try:
    local_settings = json.loads(local_settings_path.read_text()) if local_settings_path.exists() else {}
except: local_settings = {}
current_id = local_settings.get("currentProviderCodex")
if current_id and current_id != provider_id:
    row = con.execute("select settings_config from providers where app_type=? and id=?", (app_type, current_id)).fetchone()
    if row:
        try: cs = json.loads(row[0] or "{}")
        except: cs = {}
        codex_config = Path("$CODEX_DIR/config.toml")
        codex_auth = Path("$CODEX_DIR/auth.json")
        live_config = codex_config.read_text() if codex_config.exists() else ""
        live_auth = json.loads(codex_auth.read_text()) if codex_auth.exists() else {}
        if live_config and "openai_codex_adapter" not in live_config:
            cs["config"] = live_config
            cs["auth"] = live_auth
            con.execute("update providers set settings_config=? where app_type=? and id=?",
                        (json.dumps(cs, ensure_ascii=False, separators=(",",":")), app_type, current_id))
except Exception as e:
    print(f"  backfill skip: {e}")

max_sort = con.execute("select coalesce(max(sort_index),-1) from providers where app_type=?", (app_type,)).fetchone()[0]
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
     "", "third_party", now, max_sort+1,
     "Local adapter: Responses API -> Chat Completions. Auto-retry on transient errors.",
     "custom-icon", "#2563EB", json.dumps(meta, ensure_ascii=False, separators=(",",":"))))

con.execute("delete from provider_endpoints where provider_id=? and app_type=?", (provider_id, app_type))
con.execute("insert into provider_endpoints(provider_id, app_type, url, added_at) values (?,?,?,?)",
            (provider_id, app_type, base_url, now))

# set as current
con.execute("update providers set is_current=0 where app_type=?", (app_type,))
con.execute("update providers set is_current=1 where app_type=? and id=?", (app_type, provider_id))
local_settings["currentProviderCodex"] = provider_id
local_settings_path.write_text(json.dumps(local_settings, ensure_ascii=False, indent=2) + "\n")

# write live codex config
codex_dir = Path("$CODEX_DIR")
codex_dir.mkdir(parents=True, exist_ok=True)
(codex_dir / "config.toml").write_text(config + "\n")
(codex_dir / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": api_key}, ensure_ascii=False, indent=2) + "\n")

con.commit()
con.close()
print("  CC Switch integration done")
PYCC
        CC_INTEGRATED=true
        ok "CC Switch 已集成"
        open -a "CC Switch" >/dev/null 2>&1 || true
    fi
fi

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
echo -e "  健康检查:  ${CYAN}curl http://127.0.0.1:$PORT/health${NC}"
echo ""
if $CC_INTEGRATED; then
echo -e "  ${GREEN}CC Switch 已集成，直接在 CC Switch 里切换 Provider 即可${NC}"
echo -e "  重启 Codex 生效"
else
echo -e "  ${YELLOW}手动配置 Codex:${NC}"
echo -e "  在 ${CYAN}~/.codex/config.toml${NC} 中:"
echo -e "    ${GREEN}model_provider = \"custom\""
echo -e "    model = \"$MODEL\""
echo -e "    [model_providers.custom]"
echo -e "    wire_api = \"responses\""
echo -e "    requires_openai_auth = true"
echo -e "    base_url = \"http://127.0.0.1:$PORT/v1\"${NC}"
echo ""
echo -e "  在 ${CYAN}[shell_environment_policy.set]${NC} 添加:"
echo -e "    ${GREEN}ANTHROPIC_AUTH_TOKEN = \"你的API Key\"${NC}"
fi
echo ""
echo -e "  ${BOLD}管理命令:${NC}"
echo -e "    查看日志:  ${CYAN}tail -f $INSTALL_DIR/adapter.log${NC}"
echo -e "    切换配置:  ${CYAN}bash $INSTALL_DIR/switch.sh${NC}"
echo -e "    卸载:      ${CYAN}bash $INSTALL_DIR/uninstall.sh${NC}"
echo ""
