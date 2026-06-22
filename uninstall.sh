#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.openai-codex-adapter"
PLIST_PATH="$HOME/Library/LaunchAgents/com.openai-codex-adapter.plist"
CC_SWITCH_DB="$HOME/.cc-switch/cc-switch.db"
PROVIDER_ID="openai-codex-adapter"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${YELLOW}确定要卸载 OpenAI-Codex Adapter？[y/N]${NC}: "
read -r confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "已取消" && exit 0

# 停止服务
if [[ -f "$PLIST_PATH" ]]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
fi
pkill -f "adapter.py" 2>/dev/null || true

# CC Switch: 切回其他 provider 并删除
if [[ -f "$CC_SWITCH_DB" ]] && command -v python3 >/dev/null 2>&1; then
    python3 << PYCC
import json, sqlite3
from pathlib import Path

db = Path("$CC_SWITCH_DB")
provider_id = "$PROVIDER_ID"
app_type = "codex"
codex_dir = Path("$HOME/.codex")
settings_path = Path("$HOME/.cc-switch/settings.json")

con = sqlite3.connect(str(db))

# 查当前
try: local_settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
except: local_settings = {}
current = local_settings.get("currentProviderCodex")

# 如果当前是 adapter，切回其他 provider
if current == provider_id:
    row = con.execute(
        "select id, settings_config from providers where app_type=? and id<>? order by sort_index, id limit 1",
        (app_type, provider_id)
    ).fetchone()
    if row:
        fallback = row[0]
        try: settings = json.loads(row[1] or "{}")
        except: settings = {}
        config = settings.get("config", "")
        auth = settings.get("auth", {})
        if isinstance(config, str) and config:
            codex_dir.mkdir(parents=True, exist_ok=True)
            (codex_dir / "config.toml").write_text(config, encoding="utf-8")
        if isinstance(auth, dict):
            (codex_dir / "auth.json").write_text(json.dumps(auth, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        local_settings["currentProviderCodex"] = fallback
        settings_path.write_text(json.dumps(local_settings, ensure_ascii=False, indent=2) + "\n")
        con.execute("update providers set is_current=0 where app_type=?", (app_type,))
        con.execute("update providers set is_current=1 where app_type=? and id=?", (app_type, fallback))
        print(f"  Switched Codex back to provider: {fallback}")

con.execute("delete from provider_endpoints where app_type=? and provider_id=?", (app_type, provider_id))
con.execute("delete from providers where app_type=? and id=?", (app_type, provider_id))
con.commit()
con.close()
PYCC
    echo -e "${CYAN}[INFO]${NC} CC Switch provider 已清理"
fi

# 删除安装目录
rm -rf "$INSTALL_DIR"

echo -e "${GREEN}✅ 卸载完成${NC}"
