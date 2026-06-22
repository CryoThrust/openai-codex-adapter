# OpenAI-Codex Adapter

把任何 **OpenAI Chat Completions 兼容 API** 桥接到 **Codex Responses API**，内置自动重试钩子。支持 macOS / Windows。

## 一键安装

**macOS：**

```bash
curl -fsSL https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/install.sh | bash
```

**Windows (PowerShell)：**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/install.ps1 | iex"
```

安装向导会交互式引导你选择 Provider、输入 API Key 等。

## 支持的 Provider

| # | Provider | 默认模型 |
|---|----------|---------|
| 1 | DeepSeek | `deepseek-chat` |
| 2 | 讯飞星辰 (Xfyun) | `astron-code-latest` |
| 3 | Ollama (本地) | `qwen2.5-coder:7b` |
| 4 | LM Studio (本地) | `default` |
| 5 | SiliconFlow | `deepseek-ai/DeepSeek-V3` |
| 6 | OpenAI (官方) | `gpt-4o` |
| 7 | **自定义** | 任意 |

选择"自定义"可以填任意 URL，所以任何 OpenAI Chat Completions 兼容 API 都能用。

## 工作原理

```
Codex CLI
  │  Responses API 请求 (wire_api = "responses")
  ▼
┌──────────────────────────────────┐
│  Adapter (Python, :18666)        │
│                                   │
│  1. Responses → Chat Completions  │
│  2. 发送到上游 API                │
│  3. 瞬态错误自动指数退避重试       │
│  4. Chat Completions → Responses  │
└──────────────────────────────────┘
  │
  ▼
  任何 OpenAI 兼容 API
```

Codex 只支持 `wire_api = "responses"`，而绝大多数第三方 API 只有 Chat Completions 格式，所以需要适配器做格式转换。

## CC Switch 集成

如果你装了 CC Switch，安装脚本会自动：
- 在 CC Switch 的 provider 列表里新增 "OpenAI Codex Adapter"
- 切换到该 provider 并写入 Codex 配置
- 把你之前的 provider 配置回填保存，方便之后切回

之后想切换，直接在 CC Switch 的 GUI 里切就行。

卸载时也会自动切回 CC Switch 里的其他 provider。

## 开机自启

- **macOS**: LaunchAgent (`RunAtLoad` + `KeepAlive`)，开机自动启动，崩溃自动重启
- **Windows**: 计划任务 (`AtLogOn`)，登录自动启动，失败自动重试 3 次

重启电脑不用管，服务会自动起来。

## 切换 Provider

**macOS：**

```bash
bash ~/.openai-codex-adapter/switch.sh
```

**Windows (PowerShell)：**

```powershell
powershell -File "$env:USERPROFILE\.openai-codex-adapter\switch.ps1"
```

切换后自动重启适配器，CC Switch 也会同步更新。记得重启 Codex。

## 重试钩子

遇到以下错误自动指数退避重试（2s→4s→8s→16s→32s，最多 5 次）：

- HTTP 400 + 关键词：`ModelArts.81001`、`EngineInternalError`、`chat template failed`、`Inference failed`、`rate_limit`、`overloaded`、`capacity`、`temporarily unavailable`、`please retry`、`try again`
- HTTP 429（限流）
- HTTP 500/502/503/504（服务端错误）

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ADAPTER_HOST` | `127.0.0.1` | 监听地址 |
| `ADAPTER_PORT` | `18666` | 监听端口 |
| `ADAPTER_UPSTREAM` | — | 上游 API 地址（必填） |
| `ADAPTER_MODEL` | — | 模型名称（必填） |
| `ADAPTER_API_KEY` | — | API Key |
| `ADAPTER_RETRY_MAX` | `5` | 最大重试次数 |
| `ADAPTER_RETRY_DELAY` | `2.0` | 基础退避延迟（秒） |

## 管理命令

| 操作 | macOS | Windows |
|------|-------|---------|
| 健康检查 | `curl http://127.0.0.1:18666/health` | 同左 |
| 查看日志 | `tail -f ~/.openai-codex-adapter/adapter.log` | `type %USERPROFILE%\.openai-codex-adapter\adapter.log` |
| 切换 | `bash ~/.openai-codex-adapter/switch.sh` | `powershell -File switch.ps1` |
| 卸载 | `bash ~/.openai-codex-adapter/uninstall.sh` | `powershell -File uninstall.ps1` |

## 卸载

**macOS：**

```bash
bash ~/.openai-codex-adapter/uninstall.sh
```

**Windows (PowerShell)：**

```powershell
powershell -File "$env:USERPROFILE\.openai-codex-adapter\uninstall.ps1"
```

macOS 卸载时会自动把 CC Switch 切回其他 provider。

## 致谢

灵感来自 [kangarooking/xfyun-codex-adapter](https://gitee.com/kangarooking/xfyun-codex-adapter)，在其基础上增加了：
- 多 Provider 支持（DeepSeek / 讯飞 / Ollama / 任意自定义 URL）
- 自动重试钩子
- Windows 支持
- 切换脚本

## License

MIT
