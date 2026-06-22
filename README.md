# OpenAI-Codex Adapter

把任何 **OpenAI Chat Completions 兼容 API** 桥接到 **Codex Responses API** 格式，内置自动重试钩子。

## 一键安装

```bash
# 克隆后安装
git clone https://github.com/yourname/openai-codex-adapter.git
cd openai-codex-adapter
bash install.sh
```

安装向导会交互式引导你选择 Provider、输入 API Key 等。

## 支持的 Provider

| Provider | 预设地址 | 默认模型 |
|----------|---------|---------|
| DeepSeek | `api.deepseek.com/v1/chat/completions` | `deepseek-chat` |
| 讯飞星辰 | `maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions` | `astron-code-latest` |
| Ollama (本地) | `127.0.0.1:11434/v1/chat/completions` | `qwen2.5-coder:7b` |
| LM Studio (本地) | `127.0.0.1:1234/v1/chat/completions` | `default` |
| SiliconFlow | `api.siliconflow.cn/v1/chat/completions` | `DeepSeek-V3` |
| OpenAI (官方) | `api.openai.com/v1/chat/completions` | `gpt-4o` |
| **自定义** | 任意 URL | 任意模型 |

## 工作原理

```
Codex CLI
  │  发出 Responses API 请求 (wire_api = "responses")
  ▼
┌─────────────────────────────────┐
│  Adapter (Python, :18666)       │
│                                  │
│  1. Responses → Chat Completions │
│  2. 发送到上游 API               │
│  3. 遇到瞬态错误自动重试          │
│  4. Chat Completions → Responses │
└─────────────────────────────────┘
  │
  ▼
  任何 OpenAI 兼容 API
  (DeepSeek / 讯飞 / Ollama / ...)
```

**为什么需要这个？** Codex 只支持 `wire_api = "responses"`，`wire_api = "chat"` 已废弃。而绝大多数第三方 API 只提供 Chat Completions 格式，所以需要适配器做格式转换。

## 重试钩子

遇到以下错误自动指数退避重试（2s→4s→8s→16s→32s）：

- HTTP 400 + 关键词：`ModelArts.81001`、`EngineInternalError`、`chat template failed`、`Inference failed`、`rate_limit`、`overloaded`、`capacity`、`temporarily unavailable`、`please retry`、`try again`
- HTTP 429（限流）
- HTTP 500/502/503/504（服务端错误）

最多重试 5 次，可通过环境变量调整。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ADAPTER_HOST` | `127.0.0.1` | 监听地址 |
| `ADAPTER_PORT` | `18666` | 监听端口 |
| `ADAPTER_UPSTREAM` | — | 上游 API 地址（必填） |
| `ADAPTER_MODEL` | — | 模型名称（必填） |
| `ADAPTER_API_KEY` | — | API Key（通过 Authorization 头传递给上游） |
| `ADAPTER_RETRY_MAX` | `5` | 最大重试次数 |
| `ADAPTER_RETRY_DELAY` | `2.0` | 基础退避延迟（秒） |

## Codex 配置

在 `~/.codex/config.toml` 中：

```toml
model_provider = "custom"
model = "your-model-name"

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "http://127.0.0.1:18666/v1"
```

在 `[shell_environment_policy.set]` 中：

```toml
ANTHROPIC_AUTH_TOKEN = "your-api-key"
```

## 管理命令

```bash
# 健康检查
curl http://127.0.0.1:18666/health

# 查看日志
tail -f ~/.openai-codex-adapter/adapter.log

# 停止
bash ~/.openai-codex-adapter/stop.sh

# 启动
launchctl load ~/Library/LaunchAgents/com.openai-codex-adapter.plist

# 卸载
bash ~/.openai-codex-adapter/uninstall.sh

# 自动配置 Codex
bash ~/.openai-codex-adapter/config-codex.sh
```

## 文件结构

```
~/.openai-codex-adapter/
├── adapter.py          # 适配器主程序
├── config.env          # 环境变量配置
├── start.sh            # 手动启动
├── stop.sh             # 停止服务
├── uninstall.sh        # 卸载
├── config-codex.sh     # 自动配置 Codex
└── adapter.log         # 运行日志
```

## License

MIT
