#!/usr/bin/env python3
"""A scripted, stdlib-only LLM endpoint for driving real agent CLIs without quota.

Serves, on 127.0.0.1:

- ``POST /v1/responses``            OpenAI Responses API (Codex, pi ``openai-responses``)
- ``POST /v1/chat/completions``     OpenAI Chat Completions (pi ``openai-completions``)
- ``POST /v1/messages``             Anthropic Messages (pi ``anthropic-messages``)
- ``POST /v1beta/models/<m>:generateContent`` and ``:streamGenerateContent``
                                    Gemini (the Gemini CLI with GOOGLE_GEMINI_BASE_URL)
- ``GET /v1/models``, ``GET /health``

The script is the same on every API: a request whose conversation carries no
tool result is answered with ONE tool call (the agent's shell tool running
``--tool-command``, ``echo hi`` by default); a request that already carries a
tool result is answered with the final text ``--final-text`` (``done``).
The shell tool is picked from the request's own ``tools`` list, so Codex's
``shell``/``shell_command``, pi's ``bash``, Claude's ``Bash`` and Gemini's
``run_shell_command`` all work without configuration.

``--escalate`` adds ``with_escalated_permissions``/``justification`` to a
Codex shell call, which makes an interactive Codex under ``-a on-request``
raise a PermissionRequest (the ``answer_ask`` drill). ``--log`` appends one
JSON line per request (method, path, api, decision) for the verifier.

Usage: ``mock_llm_server.py [--port 0] [--log requests.jsonl]``; with port 0
the chosen port is printed as ``MOCK_LLM_PORT=<n>`` on stdout and flushed.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

SHELL_TOOL_PREFERENCE = (
    "shell_command",
    "shell",
    "exec_command",
    "local_shell",
    "bash",
    "Bash",
    "run_shell_command",
    "execute_command",
    "terminal",
)
USAGE_OPENAI = {
    "input_tokens": 120,
    "output_tokens": 12,
    "total_tokens": 132,
    "input_tokens_details": {"cached_tokens": 0},
    "output_tokens_details": {"reasoning_tokens": 0},
}


class Script:
    def __init__(self, tool_command: str, final_text: str, escalate: bool, log_path: str | None) -> None:
        self.tool_command = tool_command
        self.final_text = final_text
        self.escalate = escalate
        self.log_path = log_path
        self.lock = threading.Lock()
        self.requests = 0

    def log(self, record: dict) -> None:
        record = {"at": time.time(), **record}
        with self.lock:
            self.requests += 1
            record["n"] = self.requests
            if self.log_path:
                with open(self.log_path, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(record, ensure_ascii=True) + "\n")
        sys.stderr.write("mock-llm: " + json.dumps(record, ensure_ascii=True) + "\n")
        sys.stderr.flush()


def _tool_names(tools: object) -> list[str]:
    names: list[str] = []
    if not isinstance(tools, list):
        return names
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if name is None and isinstance(tool.get("function"), dict):
            name = tool["function"].get("name")
        if name is None and tool.get("type") == "local_shell":
            name = "local_shell"
        if isinstance(tool, dict) and isinstance(tool.get("functionDeclarations"), list):
            for declaration in tool["functionDeclarations"]:
                if isinstance(declaration, dict) and isinstance(declaration.get("name"), str):
                    names.append(declaration["name"])
            continue
        if isinstance(name, str):
            names.append(name)
    return names


def tool_parameter_keys(tools: object, name: str) -> list[str]:
    """The parameter names the agent advertises for ``name`` (for the log)."""
    if not isinstance(tools, list):
        return []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        function = tool.get("function") if isinstance(tool.get("function"), dict) else tool
        if function.get("name") != name:
            continue
        schema = function.get("parameters") or function.get("input_schema") or {}
        properties = schema.get("properties") if isinstance(schema, dict) else None
        return sorted(properties) if isinstance(properties, dict) else []
    return []


def pick_shell_tool(tools: object) -> str:
    names = _tool_names(tools)
    for preferred in SHELL_TOOL_PREFERENCE:
        if preferred in names:
            return preferred
    for name in names:
        lowered = name.lower()
        if "shell" in lowered or "bash" in lowered or "command" in lowered or "exec" in lowered:
            return name
    return names[0] if names else "shell"


def shell_arguments(tool: str, command: str, escalate: bool) -> dict:
    words = shlex.split(command)
    if tool in {"shell", "local_shell"}:
        arguments: dict = {"command": words}
    elif tool == "exec_command":
        arguments = {"cmd": command}
    else:
        arguments = {"command": command}
    if escalate and tool == "exec_command":
        # Codex 0.153's unified exec tool: the model asks to leave the
        # sandbox with sandbox_permissions, and justification is the
        # question the user sees.
        arguments["sandbox_permissions"] = "require_escalated"
        arguments["justification"] = "mock: exercise the approval path"
    elif escalate and tool in {"shell", "shell_command", "local_shell"}:
        arguments["with_escalated_permissions"] = True
        arguments["justification"] = "mock: exercise the approval path"
    if tool == "bash":
        arguments["timeout"] = 30
    return arguments


def _walk(value: object, wanted: set[str]) -> bool:
    """True when any dict in ``value`` has a ``type``/``role`` in ``wanted``."""
    if isinstance(value, dict):
        for key in ("type", "role"):
            if value.get(key) in wanted:
                return True
        if "functionResponse" in value:
            return True
        return any(_walk(item, wanted) for item in value.values())
    if isinstance(value, list):
        return any(_walk(item, wanted) for item in value)
    return False


def has_tool_result(body: dict) -> bool:
    return _walk(body.get("input"), {"function_call_output", "local_shell_call_output"}) or _walk(
        body.get("messages"), {"tool", "tool_result"}
    ) or _walk(body.get("contents"), set())


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-llm/1"
    protocol_version = "HTTP/1.1"
    script: Script

    def log_message(self, format: str, *args: object) -> None:
        return

    # -- plumbing ---------------------------------------------------------
    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        dump_dir = os.environ.get("MOCK_LLM_DUMP_DIR")
        if dump_dir:
            # Every request body verbatim, for reading an agent's tool schema.
            os.makedirs(dump_dir, exist_ok=True)
            with open(os.path.join(dump_dir, f"request-{time.time():.3f}.json"), "wb") as handle:
                handle.write(raw)
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            body = {}
        return body if isinstance(body, dict) else {}

    def _send_json(self, payload: dict, status: int = 200) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def _start_sse(self) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

    def _chunk(self, text: str) -> None:
        data = text.encode("utf-8")
        self.wfile.write(f"{len(data):x}\r\n".encode("ascii") + data + b"\r\n")
        self.wfile.flush()

    def _sse(self, payload: dict, event: str | None = None) -> None:
        head = f"event: {event}\n" if event else ""
        self._chunk(head + "data: " + json.dumps(payload) + "\n\n")

    def _end_sse(self) -> None:
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    # -- routes -----------------------------------------------------------
    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path in {"/health", "/"}:
            self._send_json({"ok": True, "requests": self.script.requests})
        elif path.rstrip("/").endswith("/models"):
            # Codex's model refresh wants ``models``; the OpenAI shape wants ``data``.
            entry = {"id": "mock-model", "object": "model", "owned_by": "mock", "slug": "mock-model", "display_name": "Mock"}
            self._send_json({"object": "list", "data": [entry], "models": [entry]})
        else:
            self._send_json({"error": {"message": f"no route {path}"}}, 404)

    def do_POST(self) -> None:
        parts = urlsplit(self.path)
        path = parts.path
        body = self._read_json()
        if path.endswith("/responses"):
            self._responses(body)
        elif path.endswith("/chat/completions"):
            self._chat(body)
        elif path.endswith("/messages"):
            self._anthropic(body)
        elif ":generateContent" in path or ":streamGenerateContent" in path:
            self._gemini(body, stream=":streamGenerateContent" in path or "alt=sse" in parts.query)
        elif path.endswith("/count_tokens") or path.endswith(":countTokens"):
            self._send_json({"input_tokens": 100, "totalTokens": 100})
        else:
            self.script.log({"method": "POST", "path": path, "api": "unknown"})
            self._send_json({"error": {"message": f"no route {path}"}}, 404)

    # -- OpenAI Responses -------------------------------------------------
    def _responses(self, body: dict) -> None:
        final = has_tool_result(body)
        tool = pick_shell_tool(body.get("tools"))
        self.script.log({"method": "POST", "path": "/v1/responses", "api": "responses", "final": final, "tool": tool, "model": body.get("model"), "tool_params": tool_parameter_keys(body.get("tools"), tool)})
        response_id = "resp_" + uuid.uuid4().hex[:12]
        if final:
            item = {
                "type": "message",
                "id": "msg_" + uuid.uuid4().hex[:12],
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": self.script.final_text, "annotations": []}],
            }
        elif tool == "local_shell":
            item = {
                "type": "local_shell_call",
                "id": "lsh_" + uuid.uuid4().hex[:12],
                "call_id": "call_" + uuid.uuid4().hex[:12],
                "status": "completed",
                "action": {"type": "exec", "command": shlex.split(self.script.tool_command)},
            }
        else:
            item = {
                "type": "function_call",
                "id": "fc_" + uuid.uuid4().hex[:12],
                "call_id": "call_" + uuid.uuid4().hex[:12],
                "status": "completed",
                "name": tool,
                "arguments": json.dumps(shell_arguments(tool, self.script.tool_command, self.script.escalate)),
            }
        response = {
            "id": response_id,
            "object": "response",
            "created_at": int(time.time()),
            "model": body.get("model") or "mock-model",
            "status": "completed",
            "output": [item],
            "usage": dict(USAGE_OPENAI),
        }
        if not body.get("stream", True):
            self._send_json(response)
            return
        self._start_sse()
        self._sse({"type": "response.created", "sequence_number": 0, "response": {**response, "status": "in_progress", "output": []}}, "response.created")
        self._sse({"type": "response.in_progress", "sequence_number": 1, "response": {**response, "status": "in_progress", "output": []}}, "response.in_progress")
        added = {**item, "status": "in_progress"}
        if item["type"] == "function_call":
            added["arguments"] = ""
        if item["type"] == "message":
            added["content"] = []
        self._sse({"type": "response.output_item.added", "sequence_number": 2, "output_index": 0, "item": added}, "response.output_item.added")
        if item["type"] == "message":
            self._sse({"type": "response.content_part.added", "sequence_number": 3, "item_id": item["id"], "output_index": 0, "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}, "response.content_part.added")
            self._sse({"type": "response.output_text.delta", "sequence_number": 4, "item_id": item["id"], "output_index": 0, "content_index": 0, "delta": self.script.final_text}, "response.output_text.delta")
            self._sse({"type": "response.output_text.done", "sequence_number": 5, "item_id": item["id"], "output_index": 0, "content_index": 0, "text": self.script.final_text}, "response.output_text.done")
            self._sse({"type": "response.content_part.done", "sequence_number": 6, "item_id": item["id"], "output_index": 0, "content_index": 0, "part": item["content"][0]}, "response.content_part.done")
        elif item["type"] == "function_call":
            self._sse({"type": "response.function_call_arguments.delta", "sequence_number": 3, "item_id": item["id"], "output_index": 0, "delta": item["arguments"]}, "response.function_call_arguments.delta")
            self._sse({"type": "response.function_call_arguments.done", "sequence_number": 4, "item_id": item["id"], "output_index": 0, "arguments": item["arguments"]}, "response.function_call_arguments.done")
        self._sse({"type": "response.output_item.done", "sequence_number": 7, "output_index": 0, "item": item}, "response.output_item.done")
        self._sse({"type": "response.completed", "sequence_number": 8, "response": response}, "response.completed")
        self._end_sse()

    # -- OpenAI Chat Completions ------------------------------------------
    def _chat(self, body: dict) -> None:
        final = has_tool_result(body)
        tool = pick_shell_tool(body.get("tools"))
        self.script.log({"method": "POST", "path": "/v1/chat/completions", "api": "chat", "final": final, "tool": tool, "model": body.get("model")})
        created = int(time.time())
        chat_id = "chatcmpl-" + uuid.uuid4().hex[:12]
        model = body.get("model") or "mock-model"
        usage = {"prompt_tokens": 120, "completion_tokens": 12, "total_tokens": 132}
        if final:
            message = {"role": "assistant", "content": self.script.final_text}
            finish = "stop"
        else:
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "call_" + uuid.uuid4().hex[:12],
                    "type": "function",
                    "function": {"name": tool, "arguments": json.dumps(shell_arguments(tool, self.script.tool_command, False))},
                }],
            }
            finish = "tool_calls"
        if not body.get("stream"):
            self._send_json({"id": chat_id, "object": "chat.completion", "created": created, "model": model, "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": usage})
            return
        self._start_sse()

        def chunk(delta: dict, finish_reason: str | None, extra: dict | None = None) -> None:
            payload = {"id": chat_id, "object": "chat.completion.chunk", "created": created, "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}
            if extra:
                payload.update(extra)
            self._sse(payload)

        if final:
            chunk({"role": "assistant", "content": ""}, None)
            chunk({"content": self.script.final_text}, None)
        else:
            call = message["tool_calls"][0]
            chunk({"role": "assistant", "content": None, "tool_calls": [{"index": 0, "id": call["id"], "type": "function", "function": {"name": call["function"]["name"], "arguments": ""}}]}, None)
            chunk({"tool_calls": [{"index": 0, "function": {"arguments": call["function"]["arguments"]}}]}, None)
        chunk({}, finish, {"usage": usage})
        self._chunk("data: [DONE]\n\n")
        self._end_sse()

    # -- Anthropic Messages -----------------------------------------------
    def _anthropic(self, body: dict) -> None:
        final = has_tool_result(body)
        tool = pick_shell_tool(body.get("tools"))
        self.script.log({"method": "POST", "path": "/v1/messages", "api": "anthropic", "final": final, "tool": tool, "model": body.get("model")})
        message_id = "msg_" + uuid.uuid4().hex[:12]
        model = body.get("model") or "mock-model"
        if final:
            block = {"type": "text", "text": self.script.final_text}
            stop = "end_turn"
        else:
            block = {"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:12], "name": tool, "input": shell_arguments(tool, self.script.tool_command, False)}
            stop = "tool_use"
        usage = {"input_tokens": 120, "output_tokens": 12}
        if not body.get("stream"):
            self._send_json({"id": message_id, "type": "message", "role": "assistant", "model": model, "content": [block], "stop_reason": stop, "stop_sequence": None, "usage": usage})
            return
        self._start_sse()
        self._sse({"type": "message_start", "message": {"id": message_id, "type": "message", "role": "assistant", "model": model, "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 120, "output_tokens": 1}}}, "message_start")
        if final:
            self._sse({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}, "content_block_start")
            self._sse({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": self.script.final_text}}, "content_block_delta")
        else:
            self._sse({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": block["id"], "name": tool, "input": {}}}, "content_block_start")
            self._sse({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}}, "content_block_delta")
        self._sse({"type": "content_block_stop", "index": 0}, "content_block_stop")
        self._sse({"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 12}}, "message_delta")
        self._sse({"type": "message_stop"}, "message_stop")
        self._end_sse()

    # -- Gemini -----------------------------------------------------------
    def _gemini(self, body: dict, *, stream: bool) -> None:
        final = has_tool_result(body)
        tool = pick_shell_tool(body.get("tools"))
        self.script.log({"method": "POST", "path": urlsplit(self.path).path, "api": "gemini", "final": final, "tool": tool, "stream": stream})
        if final:
            part = {"text": self.script.final_text}
        else:
            part = {"functionCall": {"name": tool, "args": shell_arguments(tool, self.script.tool_command, False)}}
        payload = {
            "candidates": [{"content": {"role": "model", "parts": [part]}, "finishReason": "STOP", "index": 0}],
            "usageMetadata": {"promptTokenCount": 120, "candidatesTokenCount": 12, "totalTokenCount": 132},
            "modelVersion": "mock-model",
            "responseId": uuid.uuid4().hex[:12],
        }
        if not stream:
            self._send_json(payload)
            return
        self._start_sse()
        self._sse(payload)
        self._end_sse()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MOCK_LLM_PORT", "0")))
    parser.add_argument("--log", default=os.environ.get("MOCK_LLM_LOG"))
    parser.add_argument("--tool-command", default="echo hi")
    parser.add_argument("--final-text", default="done")
    parser.add_argument("--escalate", action="store_true", help="ask Codex for escalated permissions on the shell call")
    args = parser.parse_args(argv)

    Handler.script = Script(args.tool_command, args.final_text, args.escalate, args.log)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    port = server.server_address[1]
    sys.stdout.write(f"MOCK_LLM_PORT={port}\n")
    sys.stdout.flush()
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
