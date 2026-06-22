<div align="center">

# OpenAI-Codex Adapter

**让 Codex 用上任何 OpenAI 兼容 API**

[Responses API](https://platform.openai.com/docs/api-reference/responses) → [Chat Completions API](https://platform.openai.com/docs/api-reference/chat) 格式转换 · 自动重试 · 开机自启 · CC Switch 集成

</div>

---

## 为什么需要这个？

Codex（OpenAI 的 AI 编程助手）目前只支持 `wire_api = "responses"` 格式与模型通信。而市面上绝大多数第三方 API——DeepSeek、讯飞星辰、SiliconFlow、Ollama、LM Studio 等——只提供 Chat Completions 格式。

**`wire_api = "chat"` 已被 Codex 官方废弃。**

这意味着：如果你想让 Codex 调用 DeepSeek、讯飞或其他非 OpenAI 官方的模型，必须有一个中间层把两种格式互相转换。这个适配器就是干这件事的。

```
  Codex                        你的模型
    │                              │
    │  Responses API               │  Chat Completions API
    │  (input/output/tool_call)    │  (messages/choices)
    │                              │
    └─────── Adapter :18666 ───────┘
             │
             ├── 格式转换 (双向)
             ├── 瞬态错误自动重试
             └── SSE 流式响应适配
```

## 特性

- **多 Provider 支持** — 7 个预设 + 任意自定义 URL，覆盖所有 OpenAI 兼容 API
- **自动重试钩子** — 遇到 `ModelArts.81001`、`rate_limit`、服务端 5xx 等瞬态错误时指数退避重试，最多 5 次
- **双平台** — macOS + Windows，一键安装
- **开机自启** — macOS LaunchAgent / Windows 计划任务，重启电脑不用管
- **CC Switch 集成** — 检测到 CC Switch 时自动在 provider 列表新增条目，卸载时自动切回
- **上下文窗口管理** — 模型 token 限制预设 + 适配器侧安全截断，防止上下文超限导致的 `stream disconnected` 错误
- **错误透传** — 上游错误通过 SSE 完整透传给 Codex，不再只报 "stream closed before response.completed"
- **零依赖** — 纯 Python 标准库，不需要 pip install 任何东西

## 快速开始

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/install.sh | bash
```

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/CryoThrust/openai-codex-adapter/main/install.ps1 | iex"
```

运行后会出现交互式安装向导：

```
═══════════════════════════════════════════════
  OpenAI-Codex Adapter 安装向导
═══════════════════════════════════════════════

请选择 API Provider:

  1) DeepSeek
  2) 讯飞星辰 (Xfyun)
  3) Ollama (本地)
  4) LM Studio (本地)
  5) SiliconFlow
  6) OpenAI (官方)
  7) 自定义 (Custom)

请输入编号 [1-7]:
```

选完后输入 API Key 和模型名称，脚本会自动完成剩余一切：安装适配器、注册开机自启、启动服务、自动配置 Codex、（如果有 CC Switch）集成 provider。

## 支持的 Provider

| # | Provider | 上游地址 | 默认模型 | 需要 API Key |
|---|----------|---------|---------|:------------:|
| 1 | **DeepSeek** | `api.deepseek.com/v1/chat/completions` | `deepseek-chat` | ✅ |
| 2 | **讯飞星辰** | `maas-coding-api.cn-huabei-1.xf-yun.com/v2/chat/completions` | `astron-code-latest` | ✅ |
| 3 | **Ollama** | `127.0.0.1:11434/v1/chat/completions` | `qwen2.5-coder:7b` | ❌ |
| 4 | **LM Studio** | `127.0.0.1:1234/v1/chat/completions` | `default` | ❌ |
| 5 | **SiliconFlow** | `api.siliconflow.cn/v1/chat/completions` | `deepseek-ai/DeepSeek-V3` | ✅ |
| 6 | **OpenAI** | `api.openai.com/v1/chat/completions` | `gpt-4o` | ✅ |
| 7 | **自定义** | 任意 URL | 任意模型 | 视情况 |

选择 **7) 自定义** 可以填入任何 OpenAI Chat Completions 兼容的 API 地址——自建的、内网的、第三方代理的，全部可用。

## 自动重试

适配器内置了指数退避重试机制，遇到瞬态错误不会直接崩溃，而是自动等待后重试：

```
第1次失败 → 等 2s → 第2次失败 → 等 4s → 第3次失败 → 等 8s → 第4次失败 → 等 16s → 第5次失败 → 报错
```

**可重试的错误：**

- HTTP 400 + 以下关键词之一：
  `ModelArts.81001` · `EngineInternalError` · `chat template failed` · `Inference failed` · `rate_limit` · `overloaded` · `capacity` · `temporarily unavailable` · `please retry` · `try again`
- HTTP 429（限流）
- HTTP 500 / 502 / 503 / 504（服务端错误）

不可重试的错误（如 401 鉴权失败、403 权限不足）会直接返回给 Codex。

上下文超限错误（如 `input token limit`、`context_length_exceeded`、`too many tokens`）也不会重试——重试只会浪费时间，因为同样的上下文仍然会超限。

## 上下文窗口管理

### 为什么需要？

Codex 默认不知道你使用的模型有多少 token 上限。当对话越来越长，Codex 会持续发送越来越大的上下文，直到上游 API 返回 `input token limit is XXXXX`，导致 `stream disconnected before completion: stream closed before response.completed` 错误。

### 两层防护

```
Codex 发送请求 → ① Codex 自身的 model_auto_compact_token_limit（主要防线）
               → ② 适配器侧安全截断（兜底安全网）
               → 上游 API
```

1. **Codex 的 `model_auto_compact_token_limit`**（主要防线）— 在 Codex 层面控制上下文压缩时机
2. **适配器侧截断**（安全网）— 当 Codex 的压缩没有及时触发时，适配器在转发前截断最旧的消息，保留 system prompt + 最新 N 条消息

### 模型上下文窗口预设

安装时会根据你选择的 Provider 自动检测上下文窗口大小：

| Provider | 模型 | 上下文窗口 |
|----------|------|-----------|
| DeepSeek | `deepseek-chat` (V3) | 128K |
| DeepSeek | `deepseek-reasoner` (R1) | 128K |
| 讯飞星辰 | `astron-code-latest` (GLM5.1) | 200K |
| OpenAI | `gpt-4o` | 128K |
| OpenAI | `gpt-4.1` | 1M |
| OpenAI | `o3` / `o4-mini` | 200K |
| SiliconFlow | `DeepSeek-V3` | 128K |
| Ollama | `qwen2.5-coder:7b` | 128K |
| LM Studio | varies | model-dependent |
| 自定义 | 用户定义 | 用户定义 |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ADAPTER_CONTEXT_WINDOW` | 模型预设值 | 上下文窗口大小（token 数），0 = 不限制 |
| `ADAPTER_AUTO_COMPACT_LIMIT` | 80% of context window | 自动压缩阈值，超过此值适配器会截断旧消息 |

### ⚠️ 风险提示

- **设置过大**：上下文超限报错，Codex 报 `stream disconnected`
- **设置过小**：过早压缩，丢失对话历史，模型可能忘记之前的上下文
- 适配器侧截断是**安全网**，不是替代 Codex 自身的 auto-compact 机制
- 自定义模型务必手动填写正确的上下文窗口大小

### 错误透传

之前版本中，当上游返回错误时（如上下文超限），Codex 只会报模糊的 `stream disconnected before completion: stream closed before response.completed`，看不到真正的错误原因。

现在适配器会：
1. 识别上下文超限错误（`input token limit`、`context_length_exceeded` 等），**不再无意义重试**
2. 通过 SSE 完整透传错误信息给 Codex，包括原始上游错误和建议操作
3. 确保发送 `response.completed` 事件，避免 Codex 报 "stream closed"

## CC Switch 集成

如果你装了 [CC Switch](https://github.com/nicepkg/cc-switch)，安装脚本会自动做以下操作：

1. **回填**当前 Codex provider 的配置到原 provider（保存你的旧配置）
2. **新增** `OpenAI Codex Adapter` provider 到 CC Switch 数据库
3. **切换**到新 provider 并写入 Codex 配置文件

之后你可以直接在 CC Switch 的 GUI 里切换 provider——从讯飞切到 DeepSeek，从 DeepSeek 切回 OpenAI，一键搞定。

**卸载时**会自动把 CC Switch 切回你之前的 provider，不留残留。

没有 CC Switch？完全没问题。适配器是独立的，安装时同样会自动配置 Codex `config.toml`。CC Switch 只是一个可选的 GUI 增强层。

## 切换 Provider

已安装后想换模型？不需要重新安装。

**macOS：**

```bash
bash ~/.openai-codex-adapter/switch.sh
```

**Windows：**

```powershell
powershell -File "$env:USERPROFILE\.openai-codex-adapter\switch.ps1"
```

切换脚本会：
- 显示当前配置
- 让你选择新的 Provider 或手动修改 URL / Key / 模型 / 端口
- 更新配置文件 + LaunchAgent / 计划任务
- 重启适配器服务
- 同步更新 CC Switch（如果有）

切换完成后 **重启 Codex** 即可生效。

## 开机自启

| 平台 | 机制 | 行为 |
|------|------|------|
| macOS | LaunchAgent | `RunAtLoad` + `KeepAlive`：开机启动，崩溃自动重启 |
| Windows | 计划任务 | `AtLogOn` + `RestartCount=3`：登录启动，失败重试 3 次 |

重启电脑后适配器会自动起来，无需手动操作。

## 自动配置 Codex

安装时会自动询问是否配置 Codex `config.toml`——不管你有没有 CC Switch，都会自动写入：

- `model_provider` → `"custom"`
- `model` → 你选择的模型名
- `base_url` → 适配器地址
- `ANTHROPIC_AUTH_TOKEN` → 你的 API Key

如果你选择跳过自动配置，或需要手动调整，可以编辑 `~/.codex/config.toml`：

```toml
model_provider = "custom"
model = "your-model-name"
model_context_window = 128000
model_auto_compact_token_limit = 102400

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "http://127.0.0.1:18666/v1"

[shell_environment_policy.set]
ANTHROPIC_AUTH_TOKEN = "your-api-key"
```

> `model_context_window` 和 `model_auto_compact_token_limit` 是 Codex 自身的配置，让 Codex 知道模型的上下文上限。安装脚本会自动写入，无需手动配置。

## 管理命令

| 操作 | macOS | Windows |
|------|-------|---------|
| 健康检查 | `curl http://127.0.0.1:18666/health` | 同左 |
| 查看日志 | `tail -f ~/.openai-codex-adapter/adapter.log` | 记事本打开 `adapter.log` |
| 切换 Provider | `bash ~/.openai-codex-adapter/switch.sh` | `powershell -File switch.ps1` |
| 卸载 | `bash ~/.openai-codex-adapter/uninstall.sh` | `powershell -File uninstall.ps1` |

## 卸载

**macOS：**

```bash
bash ~/.openai-codex-adapter/uninstall.sh
```

**Windows：**

```powershell
powershell -File "$env:USERPROFILE\.openai-codex-adapter\uninstall.ps1"
```

卸载会：
- 停止并移除后台服务
- 删除安装目录
- （macOS + CC Switch）自动切回之前的 provider

## 环境变量

所有配置都可以通过环境变量覆盖，方便高级用户自定义：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ADAPTER_HOST` | `127.0.0.1` | 监听地址 |
| `ADAPTER_PORT` | `18666` | 监听端口 |
| `ADAPTER_UPSTREAM` | — | 上游 API 地址（**必填**） |
| `ADAPTER_MODEL` | — | 模型名称（**必填**） |
| `ADAPTER_API_KEY` | — | API Key（通过 `Authorization` 头传递给上游） |
| `ADAPTER_RETRY_MAX` | `5` | 最大重试次数 |
| `ADAPTER_RETRY_DELAY` | `2.0` | 退避基础延迟（秒），实际 = `delay × 2^(attempt-1)` |
| `ADAPTER_CONTEXT_WINDOW` | 模型预设值 | 上下文窗口大小（token），0 = 不限制，适配器侧安全截断 |
| `ADAPTER_AUTO_COMPACT_LIMIT` | 80% of context window | 适配器侧自动压缩阈值，超过此值截断旧消息 |

## 文件结构

安装完成后，所有文件在 `~/.openai-codex-adapter/`（macOS）或 `%USERPROFILE%\.openai-codex-adapter\`（Windows）：

```
.openai-codex-adapter/
├── adapter.py        # 适配器主程序
├── config.env        # 配置文件（环境变量）
├── adapter.log       # 运行日志
├── switch.sh/ps1     # 切换脚本
└── uninstall.sh/ps1  # 卸载脚本
```

## 致谢

灵感来自 [kangarooking/xfyun-codex-adapter](https://gitee.com/kangarooking/xfyun-codex-adapter)，本项目在其基础上扩展了：

- ✅ 多 Provider 支持（不仅限于讯飞）
- ✅ 自动重试钩子（指数退避）
- ✅ Windows 支持
- ✅ 切换脚本（已安装后切换 Provider）
- ✅ CC Switch 双向集成（安装时自动注册，卸载时自动切回）
- ✅ 上下文窗口管理（模型预设 + 适配器侧安全截断）
- ✅ 错误透传（上游错误完整展示，不再只报 stream disconnected）

## License

MIT
