#!/usr/bin/env python3
"""
OpenAI Chat Completions → Codex Responses API 通用适配器
支持任何 OpenAI 兼容 API (DeepSeek / 讯飞 / Ollama / LMStudio / 任意自建)
内置自动重试钩子，遇到瞬态错误自动指数退避重试
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
            return
        except Exception as exc:
            traceback.print_exc()
            self._json(500, {"error": str(exc)})

    # ── 上游请求 + 重试 ─────────────────────────────
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
            err.read = lambda: raw
            return body
        except Exception:
            return ""

    def _is_retryable(self, err):
        if err.code in RETRY_CODES:
            body = self._read_err(err)
            for kw in RETRY_KEYWORDS:
                if kw.lower() in body.lower():
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

    # ── 响应处理 ─────────────────────────────────────
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
        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        result = response_shell("resp_" + uuid.uuid4().hex, UPSTREAM_MODEL, "completed", output=output)
        self._json(200, result)

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

        try:
            data = self._fetch_with_retry(auth, upstream_body)
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")
            print(f"upstream HTTP {err.code}: {detail[:200]}", flush=True)
            data = {"choices": [{"message": {"content": f"上游接口错误 HTTP {err.code}: {detail[:1200]}"}}]}
        except urllib.error.URLError as err:
            print(f"upstream URL error: {err}", flush=True)
            data = {"choices": [{"message": {"content": f"上游连接失败: {err}"}}]}

        message = (data.get("choices") or [{}])[0].get("message") or {}
        output = output_from_chat_message(message)
        usage = data.get("usage")
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
        print("❌ ADAPTER_UPSTREAM 未设置，请运行安装脚本或设置环境变量", flush=True)
        sys.exit(1)
    if not UPSTREAM_MODEL:
        print("❌ ADAPTER_MODEL 未设置，请运行安装脚本或设置环境变量", flush=True)
        sys.exit(1)

    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"🚀 OpenAI-Codex Adapter on http://{HOST}:{PORT}", flush=True)
    print(f"   upstream: {UPSTREAM}", flush=True)
    print(f"   model:    {UPSTREAM_MODEL}", flush=True)
    print(f"   retry:    max {RETRY_MAX}, base delay {RETRY_DELAY}s", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
