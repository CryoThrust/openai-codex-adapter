#!/usr/bin/env python3
"""
OpenAI Chat Completions → Codex Responses API 通用适配器
支持任何 OpenAI 兼容 API (DeepSeek / 讯飞 / Ollama / LMStudio / 任意自建)
内置自动重试钩子，遇到瞬态错误自动指数退避重试
跨平台: macOS / Windows / Linux
"""
import json
import os
import socket
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ── 配置（全部可通过环境变量覆盖）──────────────────────
HOST = os.environ.get("ADAPTER_HOST", "127.0.0.1")
PORT = int(os.environ.get("ADAPTER_PORT", "18666"))
UPSTREAM = os.environ.get("ADAPTER_UPSTREAM", "")
UPSTREAM_MODEL = os.environ.get("ADAPTER_MODEL", "")
API_KEY = os.environ.get("ADAPTER_API_KEY", "")

RETRY_MAX = int(os.environ.get("ADAPTER_RETRY_MAX", "5"))
RETRY_DELAY = float(os.environ.get("ADAPTER_RETRY_DELAY", "2.0"))
RETRY_CODES = {400, 429, 500, 502, 503, 504}
RETRY_KEYWORDS = [
    "ModelArts.81001", "EngineInternalError", "chat template failed",
    "Inference failed", "rate_limit", "overloaded", "capacity",
    "temporarily unavailable", "please retry", "try again",
]

# ── 不可重试的关键词（上下文超限等，重试无意义）──────
RETRY_NON_RETRYABLE_KEYWORDS = [
    "input token limit", "context_length_exceeded", "too many tokens",
    "NotEnoughCvError", "maximum context length", "context window",
    "token limit", "max_tokens",
]

# ── 模型上下文窗口预设 ─────────────────────────────────
MODEL_CONTEXT_LIMITS = {
    # DeepSeek
    "deepseek-chat": 128000,
    "deepseek-reasoner": 128000,
    "deepseek-coder": 128000,
    # 讯飞星辰
    "astron-code-latest": 200000,
    "glm-5.1": 200000,
    # OpenAI
    "gpt-4o": 128000,
    "gpt-4o-mini": 128000,
    "gpt-4.1": 1000000,
    "gpt-4.1-mini": 1000000,
    "gpt-4.1-nano": 1000000,
    "o3": 200000,
    "o4-mini": 200000,
    # SiliconFlow
    "deepseek-ai/DeepSeek-V3": 128000,
    "deepseek-ai/DeepSeek-R1": 128000,
    # Ollama (model-dependent, sensible default)
    "qwen2.5-coder:7b": 128000,
    "qwen2.5-coder:14b": 128000,
    "qwen2.5-coder:32b": 128000,
    "codestral": 32000,
    "llama3.1:8b": 128000,
    "mistral:7b": 32000,
    # LM Studio
    "default": 128000,
}

# 上下文窗口大小 (0 = 不限制，由上游自行处理)
CONTEXT_WINDOW = int(os.environ.get("ADAPTER_CONTEXT_WINDOW", "0"))
# 自动压缩阈值 (默认 80%，给输出留余量)
AUTO_COMPACT_LIMIT = int(os.environ.get("ADAPTER_AUTO_COMPACT_LIMIT", "0"))


# ── 工具函数 ──────────────────────────────────────────
def extract_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(p for item in value if (p := extract_text(item)))
    if isinstance(value, dict):
        for k in ("text", "content", "output", "result"):
            if k in value:
                t = extract_text(value[k])
                if t:
                    return t
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def normalize_role(role):
    if role in ("developer", "system"):
        return "system"
    if role in ("assistant", "tool"):
        return role
    return "user"


def responses_to_messages(body):
    messages = []
    instructions = body.get("instructions")
    if instructions:
        messages.append({"role": "system", "content": extract_text(instructions)})

    inp = body.get("input", "")
    if isinstance(inp, str):
        if inp.strip():
            messages.append({"role": "user", "content": inp})
        return messages or [{"role": "user", "content": ""}]

    if isinstance(inp, list):
        for item in inp:
            if not isinstance(item, dict):
                t = extract_text(item)
                if t:
                    messages.append({"role": "user", "content": t})
                continue
            typ = item.get("type")
            if typ == "function_call_output":
                messages.append({
                    "role": "tool",
                    "tool_call_id": item.get("call_id") or item.get("id") or "call_unknown",
                    "content": extract_text(item.get("output")),
                })
            elif typ == "function_call":
                messages.append({
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": item.get("call_id") or item.get("id") or "call_unknown",
                        "type": "function",
                        "function": {
                            "name": item.get("name") or "unknown",
                            "arguments": item.get("arguments") or "{}",
                        },
                    }],
                })
            else:
                role = normalize_role(item.get("role") or ("assistant" if typ == "message" else "user"))
                t = extract_text(item.get("content"))
                if not t and typ:
                    t = extract_text(item)
                if t:
                    messages.append({"role": role, "content": t})
    return messages or [{"role": "user", "content": ""}]


def responses_tools_to_chat_tools(tools):
    out = []
    for tool in tools or []:
        if not isinstance(tool, dict) or tool.get("type") != "function":
            continue
        name = tool.get("name") or tool.get("function", {}).get("name")
        if not name:
            continue
        out.append({
            "type": "function",
            "function": {
                "name": name,
                "description": tool.get("description") or tool.get("function", {}).get("description") or "",
                "parameters": tool.get("parameters") or tool.get("function", {}).get("parameters") or {"type": "object", "properties": {}},
            },
        })
    return out


def sse(handler, event, data):
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    try:
        handler.wfile.write(f"event: {event}\n".encode())
        handler.wfile.write(f"data: {payload}\n\n".encode())
        handler.wfile.flush()
        return True
    except (BrokenPipeError, ConnectionResetError, socket.timeout):
        return False


def response_shell(rid, model, status, output=None, usage=None):
    body = {
        "id": rid, "object": "response", "created_at": int(time.time()),
        "status": status, "model": model, "output": output or [],
        "parallel_tool_calls": True, "tool_choice": "auto",
    }
    if usage:
        body["usage"] = usage
    return body


def output_from_chat_message(message):
    output = []
    text = message.get("content") or ""
    if text:
        output.append({
            "id": "msg_" + uuid.uuid4().hex, "type": "message", "status": "completed",
            "role": "assistant", "content": [{"type": "output_text", "text": text, "annotations": []}],
        })
    for tc in message.get("tool_calls") or []:
        fn = tc.get("function") or {}
        output.append({
            "id": tc.get("id") or "call_" + uuid.uuid4().hex, "type": "function_call",
            "status": "completed", "name": fn.get("name") or "unknown",
            "call_id": tc.get("id") or "call_" + uuid.uuid4().hex,
            "arguments": fn.get("arguments") or "{}",
        })
    return output


# ── 上下文窗口管理 ─────────────────────────────────────

def get_effective_context_window():
    """获取生效的上下文窗口大小：环境变量 > 模型预设 > 0(不限)"""
    if CONTEXT_WINDOW > 0:
        return CONTEXT_WINDOW
    limit = MODEL_CONTEXT_LIMITS.get(UPSTREAM_MODEL, 0)
    return limit


def get_effective_compact_limit():
    """获取生效的自动压缩阈值"""
    if AUTO_COMPACT_LIMIT > 0:
        return AUTO_COMPACT_LIMIT
    window = get_effective_context_window()
    if window > 0:
        return int(window * 0.8)
    return 0


def estimate_message_tokens(msg):
    """粗略估算消息的 token 数（中文约 1.5 字/token，英文约 4 字符/token，取中间值约 2 字符/token）"""
    count = 0
    content = msg.get("content")
    if content:
        count += len(content) // 2
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function") or {}
        count += len(fn.get("arguments") or "") // 2
        count += len(fn.get("name") or "") // 2
    return max(count, 10)  # 每条消息至少算 10 token


def truncate_messages(messages, max_tokens):
    """截断消息列表：保留 system prompt + 最后 N 条消息，确保不超过 max_tokens"""
    if max_tokens <= 0 or not messages:
        return messages, False

    total = sum(estimate_message_tokens(m) for m in messages)
    if total <= max_tokens:
        return messages, False

    # 分离 system 消息和其余消息
    system_msgs = [m for m in messages if m.get("role") == "system"]
    other_msgs = [m for m in messages if m.get("role") != "system"]

    system_tokens = sum(estimate_message_tokens(m) for m in system_msgs)
    remaining_budget = max_tokens - system_tokens

    if remaining_budget <= 0:
        # system prompt 就已经超了，只保留 system + 最后一条
        print(f"[context truncation] WARNING: system prompt alone ({system_tokens} tokens) exceeds budget ({max_tokens})", flush=True)
        return system_msgs + (other_msgs[-1:] if other_msgs else []), True

    # 从最新的消息开始保留
    kept = []
    used = 0
    for msg in reversed(other_msgs):
        msg_tokens = estimate_message_tokens(msg)
        if used + msg_tokens > remaining_budget:
            break
        kept.append(msg)
        used += msg_tokens

    kept.reverse()
    result = system_msgs + kept
    dropped = len(messages) - len(result)
    print(f"[context truncation] {dropped} messages dropped (est {total} -> {system_tokens + used} tokens, limit {max_tokens})", flush=True)
    return result, True


# ── Handler ───────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    server_version = "openai-codex-adapter/1.0"

    def log_message(self, fmt, *args):
        print(f"[{time.strftime('%H:%M:%S')}] {fmt % args}", flush=True)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/health", "/v1/health"):
            self._json(200, {"ok": True, "upstream": UPSTREAM, "model": UPSTREAM_MODEL})
            return
        if path in ("/models", "/v1/models"):
            self._json(200, {
                "object": "list",
                "data": [{"id": UPSTREAM_MODEL, "object": "model", "created": int(time.time()), "owned_by": "custom"}],
            })
            return
        self.send_error(404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not (path.startswith("/v1/responses") or path.startswith("/responses")):
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            raw = self.rfile.read(length)
            body = json.loads(raw.decode("utf-8") or "{}")
            auth = self.headers.get("authorization") or self.headers.get("Authorization")
            if not auth:
                self.send_error(401, "Missing Authorization header")
                return

            messages = responses_to_messages(body)

            # 上下文窗口安全截断
            compact_limit = get_effective_compact_limit()
            if compact_limit > 0:
                messages, truncated = truncate_messages(messages, compact_limit)
                if truncated:
                    print(f"[context] messages truncated to fit {compact_limit} token limit", flush=True)

            max_tokens = body.get("max_output_tokens") or body.get("max_tokens") or 4096
            upstream_body = {
                "model": UPSTREAM_MODEL,
                "messages": messages,
                "stream": False,
                "max_tokens": max_tokens,
            }
            chat_tools = responses_tools_to_chat_tools(body.get("tools"))
            if chat_tools:
                upstream_body["tools"] = chat_tools
                if body.get("tool_choice") and body.get("tool_choice") != "auto":
                    upstream_body["tool_choice"] = body.get("tool_choice")
            if "temperature" in body:
                upstream_body["temperature"] = body["temperature"]

            if body.get("stream", True) is not False:
                self._handle_stream(auth, upstream_body)
            else:
                self._handle_non_stream(auth, upstream_body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            # Codex 客户端已断开，无法再发送任何数据
            print(f"[warn] client disconnected during request", flush=True)
            return
        except Exception as exc:
            traceback.print_exc()
            # 如果 headers 还没发送，可以发 JSON 错误
            try:
                self._json(500, {"error": {"message": str(exc), "type": "adapter_error"}})
            except Exception:
                # headers 已发送（stream 模式），无法再发 JSON
                print(f"[error] cannot send error to client (stream already started): {exc}", flush=True)

    def _upstream_req(self, auth, body):
        req = urllib.request.Request(
            UPSTREAM,
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": auth,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        return urllib.request.urlopen(req, timeout=600)

    def _read_err(self, err):
        try:
            raw = err.read()
            body = raw.decode("utf-8", "replace")
            # 保存 body 供后续重新读取
            err._saved_body = raw
            err._saved_text = body
            err.read = lambda: raw
            return body
        except Exception:
            # 如果之前已经读过，使用缓存的
            if hasattr(err, '_saved_text'):
                return err._saved_text
            return ""

    def _is_retryable(self, err):
        if err.code in RETRY_CODES:
            body = self._read_err(err)
            body_lower = body.lower()
            # 先检查不可重试关键词（上下文超限等，重试无意义）
            for kw in RETRY_NON_RETRYABLE_KEYWORDS:
                if kw.lower() in body_lower:
                    print(f"[context overflow] non-retryable: {kw} — {body[:200]}", flush=True)
                    return False, body
            for kw in RETRY_KEYWORDS:
                if kw.lower() in body_lower:
                    return True, body
            if err.code in (429, 500, 502, 503, 504):
                return True, body
        return False, ""

    def _fetch_once(self, auth, body):
        with self._upstream_req(auth, body) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def _fetch_with_retry(self, auth, body):
        last_err = ""
        for attempt in range(1, RETRY_MAX + 1):
            try:
                return self._fetch_once(auth, body)
            except urllib.error.HTTPError as err:
                retryable, detail = self._is_retryable(err)
                if not retryable:
                    raise
                delay = RETRY_DELAY * (2 ** (attempt - 1))
                print(f"[retry {attempt}/{RETRY_MAX}] HTTP {err.code}, waiting {delay:.1f}s — {detail[:150]}", flush=True)
                if attempt < RETRY_MAX:
                    time.sleep(delay)
                last_err = detail
            except urllib.error.URLError as err:
                delay = RETRY_DELAY * (2 ** (attempt - 1))
                print(f"[retry {attempt}/{RETRY_MAX}] URL error: {err}, waiting {delay:.1f}s", flush=True)
                if attempt < RETRY_MAX:
                    time.sleep(delay)
                last_err = str(err)
        raise urllib.error.HTTPError(UPSTREAM, 503, f"Max retries exhausted: {last_err[:300]}", None, None)

    def _handle_non_stream(self, auth, upstream_body):
        try:
            data = self._fetch_with_retry(auth, upstream_body)
        except urllib.error.HTTPError as err:
            payload = err.read()
            self.send_response(err.code)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            return
        usage = data.get("usage")
        if usage:
            print(f"[tokens] input={usage.get('prompt_tokens',0)} output={usage.get('completion_tokens',0)} total={usage.get('total_tokens',0)}", flush=True)
        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        result = response_shell("resp_" + uuid.uuid4().hex, UPSTREAM_MODEL, "completed", output=output)
        self._json(200, result)

    def _send_error_response(self, rid, error_msg, error_code=None):
        """在 SSE 流中发送错误响应，确保 Codex 收到 response.completed 而非 stream disconnected"""
        err_item = {
            "id": "msg_" + uuid.uuid4().hex, "type": "message", "status": "completed",
            "role": "assistant", "content": [{"type": "output_text", "text": error_msg, "annotations": []}],
        }
        sse(self, "response.output_item.added", {
            "type": "response.output_item.added", "response_id": rid, "output_index": 0, "item": err_item,
        })
        sse(self, "response.content_part.added", {
            "type": "response.content_part.added", "response_id": rid, "item_id": err_item["id"],
            "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []},
        })
        sse(self, "response.output_text.delta", {
            "type": "response.output_text.delta", "response_id": rid, "item_id": err_item["id"],
            "output_index": 0, "content_index": 0, "delta": error_msg,
        })
        sse(self, "response.output_text.done", {
            "type": "response.output_text.done", "response_id": rid, "item_id": err_item["id"],
            "output_index": 0, "content_index": 0, "text": error_msg,
        })
        sse(self, "response.content_part.done", {
            "type": "response.content_part.done", "response_id": rid, "item_id": err_item["id"],
            "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": error_msg, "annotations": []},
        })
        sse(self, "response.output_item.done", {
            "type": "response.output_item.done", "response_id": rid, "output_index": 0, "item": err_item,
        })
        # 关键：必须发送 response.completed，否则 Codex 报 "stream closed before response.completed"
        sse(self, "response.completed", {
            "type": "response.completed",
            "response": response_shell(rid, UPSTREAM_MODEL, "completed", output=[err_item]),
        })
        self.close_connection = True

    def _handle_stream(self, auth, upstream_body):
        rid = "resp_" + uuid.uuid4().hex
        self.send_response(200)
        self.send_header("content-type", "text/event-stream; charset=utf-8")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        if not sse(self, "response.created", {
            "type": "response.created",
            "response": response_shell(rid, UPSTREAM_MODEL, "in_progress"),
        }):
            return

        # ── 获取上游响应 ──────────────────────────────
        upstream_error_msg = None
        data = None
        try:
            data = self._fetch_with_retry(auth, upstream_body)
        except urllib.error.HTTPError as err:
            # 使用缓存的 body（_read_err 已经读过并保存了）
            detail = getattr(err, '_saved_text', '') or ''
            if not detail:
                try:
                    detail = err.read().decode("utf-8", "replace")
                except Exception:
                    detail = ''
            print(f"upstream HTTP {err.code}: {detail[:300]}", flush=True)
            # 检测上下文超限错误
            is_context_overflow = any(kw.lower() in detail.lower() for kw in RETRY_NON_RETRYABLE_KEYWORDS)
            if is_context_overflow:
                upstream_error_msg = (
                    f"⚠️ 上下文超限 (HTTP {err.code}): 对话过长超出模型 token 限制。\n"
                    f"上游原始错误: {detail[:500]}\n\n"
                    f"建议:\n"
                    f"  1) 在 ~/.codex/config.toml 设置 model_auto_compact_token_limit\n"
                    f"  2) 设置环境变量 ADAPTER_CONTEXT_WINDOW 和 ADAPTER_AUTO_COMPACT_LIMIT\n"
                    f"  3) 开启新会话减少上下文长度"
                )
            else:
                upstream_error_msg = f"❌ 上游接口错误 HTTP {err.code}\n原始响应: {detail[:1500]}"
        except urllib.error.URLError as err:
            print(f"upstream URL error: {err}", flush=True)
            upstream_error_msg = f"❌ 上游连接失败: {err}"
        except Exception as err:
            print(f"upstream unexpected error: {err}", flush=True)
            upstream_error_msg = f"❌ 上游异常: {err}"

        # ── 如果上游出错，通过 SSE 发送错误信息（确保 Codex 收到完整响应）──
        if upstream_error_msg:
            self._send_error_response(rid, upstream_error_msg)
            return

        # ── 正常响应处理 ──────────────────────────────
        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        usage = data.get("usage")
        if usage:
            print(f"[tokens] input={usage.get('prompt_tokens',0)} output={usage.get('completion_tokens',0)} total={usage.get('total_tokens',0)}", flush=True)
        mapped_usage = None
        if usage:
            mapped_usage = {
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0),
                "total_tokens": usage.get("total_tokens", 0),
            }

        for idx, item in enumerate(output):
            if not sse(self, "response.output_item.added", {
                "type": "response.output_item.added", "response_id": rid, "output_index": idx, "item": item,
            }):
                return
            if item.get("type") == "message":
                part = item["content"][0]
                for evt, d in [
                    ("response.content_part.added", {"type": "response.content_part.added", "response_id": rid, "item_id": item["id"], "output_index": idx, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}),
                    ("response.output_text.delta", {"type": "response.output_text.delta", "response_id": rid, "item_id": item["id"], "output_index": idx, "content_index": 0, "delta": part.get("text", "")}),
                    ("response.output_text.done", {"type": "response.output_text.done", "response_id": rid, "item_id": item["id"], "output_index": idx, "content_index": 0, "text": part.get("text", "")}),
                    ("response.content_part.done", {"type": "response.content_part.done", "response_id": rid, "item_id": item["id"], "output_index": idx, "content_index": 0, "part": part}),
                ]:
                    if not sse(self, evt, d):
                        return
            if not sse(self, "response.output_item.done", {
                "type": "response.output_item.done", "response_id": rid, "output_index": idx, "item": item,
            }):
                return

        sse(self, "response.completed", {
            "type": "response.completed",
            "response": response_shell(rid, UPSTREAM_MODEL, "completed", output=output, usage=mapped_usage),
        })
        self.close_connection = True

    def _json(self, code, data):
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))


def main():
    if not UPSTREAM:
        print("ERROR: ADAPTER_UPSTREAM not set. Run install script or set env var.", flush=True)
        sys.exit(1)
    if not UPSTREAM_MODEL:
        print("ERROR: ADAPTER_MODEL not set. Run install script or set env var.", flush=True)
        sys.exit(1)

    ctx_window = get_effective_context_window()
    ctx_compact = get_effective_compact_limit()

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"OpenAI-Codex Adapter on http://{HOST}:{PORT}", flush=True)
    print(f"  upstream:  {UPSTREAM}", flush=True)
    print(f"  model:     {UPSTREAM_MODEL}", flush=True)
    print(f"  retry:     max {RETRY_MAX}, base delay {RETRY_DELAY}s", flush=True)
    if ctx_window > 0:
        print(f"  context:   {ctx_window} tokens (compact at {ctx_compact})", flush=True)
        preset = MODEL_CONTEXT_LIMITS.get(UPSTREAM_MODEL)
        if preset and CONTEXT_WINDOW == 0:
            print(f"  (preset:   {UPSTREAM_MODEL} = {preset})", flush=True)
        elif CONTEXT_WINDOW > 0:
            print(f"  (custom:   ADAPTER_CONTEXT_WINDOW={CONTEXT_WINDOW})", flush=True)
    else:
        print(f"  context:   unlimited (no preset for {UPSTREAM_MODEL}, set ADAPTER_CONTEXT_WINDOW)", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
