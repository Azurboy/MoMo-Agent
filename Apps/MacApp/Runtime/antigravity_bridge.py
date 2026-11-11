"""Official Antigravity CLI (`agy`) subscription adapter and loopback OpenAI-compatible bridge."""
from __future__ import annotations

import asyncio
import contextlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit
import uuid

_AGY_TOTAL_SEM = threading.BoundedSemaphore(3)
_AGY_BACKGROUND_SEM = threading.BoundedSemaphore(1)
MAX_PROMPT_UTF8_BYTES = 140_000

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")
MODEL_LINE_RE = re.compile(r"^\s*([a-z0-9][a-z0-9._-]+)(?:\t+|\s{2,})(.+?)\s*$")
URL_RE = re.compile(r"https://[^\s\x1b<>\"']+")

DEFAULT_ANTIGRAVITY_MODELS: list[str] = [
    "gemini-4-carbon-high",
    "gemini-4-carbon-medium",
    "gemini-4-argon-high",
    "gemini-4-argon-medium",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "claude-sonnet-5-5-medium",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
]

PREFERRED_MODEL_ORDER: tuple[str, ...] = (
    "gemini-4-carbon-high",
    "claude-opus-5-5-high",
    "claude-sonnet-5-5-high",
    "gemini-4-carbon-medium",
    "gemini-4-argon-high",
    "claude-sonnet-5-5-medium",
    "gemini-3.8-flash-high",
    "gemini-3.8-flash-medium",
)

TOOL_ENVELOPE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "content": {"type": "string"},
        "tool_calls": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "arguments_json": {"type": "string"},
                },
                "required": ["name", "arguments_json"],
            },
        },
    },
    "required": ["content", "tool_calls"],
}


def find_antigravity_cli(name: str = "agy") -> str | None:
    """Locate the official Antigravity CLI (`agy`) binary on this Mac."""
    override = os.environ.get("MOMO_ANTIGRAVITY_CLI", "").strip()
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)

    found = shutil.which(name)
    if found and os.access(found, os.X_OK):
        return found

    home = Path.home()
    candidates = (
        home / ".local/bin" / name,
        home / ".gemini/antigravity-cli/bin" / name,
        Path("/opt/homebrew/bin") / name,
        Path("/usr/local/bin") / name,
    )
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def is_antigravity_authorization_url(value: str) -> bool:
    """Validate that a login URL is an official Google OAuth endpoint."""
    try:
        url = urlsplit(value)
    except ValueError:
        return False
    if url.scheme != "https" or url.username or url.password or url.port not in {None, 443}:
        return False
    if url.hostname != "accounts.google.com":
        return False
    return url.path.startswith(("/o/oauth2", "/signin", "/v3/signin"))


def _empty_sandbox_dir(base_dir: Path | None = None) -> Path:
    if base_dir is not None:
        folder = Path(base_dir) / "superagent/antigravity-sandbox"
    else:
        folder = Path(tempfile.gettempdir()) / f"momo-antigravity-sandbox-{os.getuid()}"
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    return folder


def _agy_env() -> dict[str, str]:
    env = dict(os.environ)
    local_bin = str(Path.home() / ".local/bin")
    agy_bin = str(Path.home() / ".gemini/antigravity-cli/bin")
    existing_path = env.get("PATH", "/usr/bin:/bin")
    parts = [p for p in (local_bin, agy_bin, "/opt/homebrew/bin", "/usr/local/bin") if p not in existing_path.split(":")]
    if parts:
        env["PATH"] = ":".join([*parts, existing_path])
    env["NO_COLOR"] = "1"
    return env


def parse_antigravity_models_output(raw_output: str) -> list[str]:
    """Parse `agy models` stdout into ordered model IDs."""
    cleaned = ANSI_ESCAPE_RE.sub("", raw_output or "")
    discovered: list[str] = []
    seen: set[str] = set()
    for raw_line in cleaned.splitlines():
        match = MODEL_LINE_RE.match(raw_line)
        if not match:
            continue
        model_id = match.group(1).strip()
        if model_id in {"id", "model", "models", "available"}:
            continue
        if model_id not in seen:
            seen.add(model_id)
            discovered.append(model_id)
    if not discovered:
        return []
    preferred = [m for m in PREFERRED_MODEL_ORDER if m in seen]
    rest = [m for m in discovered if m not in set(preferred)]
    return [*preferred, *rest]


def list_antigravity_models(cli_path: str | None = None, *, timeout: float = 15.0) -> tuple[bool, list[str]]:
    """Return `(connected, models)` by querying `agy models`."""
    cli = cli_path or find_antigravity_cli()
    if not cli:
        return False, list(DEFAULT_ANTIGRAVITY_MODELS)
    try:
        proc = subprocess.run(
            [cli, "models"],
            cwd=str(_empty_sandbox_dir()),
            env=_agy_env(),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, list(DEFAULT_ANTIGRAVITY_MODELS)
    models = parse_antigravity_models_output((proc.stdout or "") + "\n" + (proc.stderr or ""))
    if proc.returncode == 0 and models:
        return True, models
    return False, list(DEFAULT_ANTIGRAVITY_MODELS)


def login_antigravity(
    authorize=lambda **fields: None,
    *,
    timeout: float = 300.0,
) -> tuple[bool, list[str]]:
    """Drive official `agy` sign-in and surface only validated Google OAuth URLs."""
    cli = find_antigravity_cli()
    if not cli:
        raise RuntimeError("请先安装 Antigravity CLI (agy)，再使用 Antigravity 订阅登录。")

    connected, models = list_antigravity_models(cli)
    if connected:
        return True, models

    deadline = time.monotonic() + timeout
    master_fd, slave_fd = pty.openpty()
    child = subprocess.Popen(
        [cli],
        cwd=str(_empty_sandbox_dir()),
        env=_agy_env(),
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        start_new_session=True,
        close_fds=True,
    )
    os.close(slave_fd)

    emitted_urls: set[str] = set()
    buffer = ""
    last_probe = 0.0
    sent_enter = False
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master_fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(master_fd, 4096).decode("utf-8", errors="replace")
                except OSError:
                    chunk = ""
                if chunk:
                    buffer = (buffer + ANSI_ESCAPE_RE.sub("", chunk))[-16384:]
                    for candidate in URL_RE.findall(buffer):
                        trimmed = candidate.rstrip(".,;:)]}")
                        if trimmed not in emitted_urls and is_antigravity_authorization_url(trimmed):
                            emitted_urls.add(trimmed)
                            authorize(url=trimmed, expiresAt=time.time() + max(30.0, deadline - time.monotonic()))
                    if not sent_enter and ("sign in" in buffer.lower() or "login" in buffer.lower() or "authenticate" in buffer.lower()):
                        with contextlib.suppress(OSError):
                            os.write(master_fd, b"\r")
                        sent_enter = True

            now = time.monotonic()
            if now - last_probe >= 2.5:
                last_probe = now
                connected, models = list_antigravity_models(cli, timeout=8.0)
                if connected:
                    return True, models

            if child.poll() is not None:
                break

        connected, models = list_antigravity_models(cli, timeout=10.0)
        return connected, models
    finally:
        with contextlib.suppress(OSError):
            os.close(master_fd)
        if child.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=1.5)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                with contextlib.suppress(Exception):
                    child.wait(timeout=1.0)


def _extract_content_text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                btype = str(item.get("type") or "")
                if btype in {"text", "input_text", "output_text"}:
                    parts.append(str(item.get("text") or ""))
        return "\n".join(p for p in parts if p)
    return str(content)


def _normalize_openai_tools(tools: list[dict] | None) -> list[dict]:
    normalized: list[dict] = []
    for entry in tools or ():
        if not isinstance(entry, dict):
            continue
        fn = entry.get("function") if entry.get("type") == "function" else entry
        if not isinstance(fn, dict):
            continue
        name = str(fn.get("name") or "").strip()
        if not name:
            continue
        normalized.append(
            {
                "name": name,
                "description": str(fn.get("description") or "").strip(),
                "parameters": fn.get("parameters") if isinstance(fn.get("parameters"), dict) else {"type": "object", "properties": {}},
            }
        )
    return normalized


def build_antigravity_prompt(
    messages: list[dict],
    *,
    tools: list[dict] | None = None,
    tool_choice=None,
) -> tuple[str, dict | None, set[str]]:
    """Build a deterministic single-turn `agy -p` prompt and optional `--json-schema`."""
    declared_tools = [] if tool_choice == "none" else _normalize_openai_tools(tools)
    declared_names = {t["name"] for t in declared_tools}

    forced_tool_name: str | None = None
    if isinstance(tool_choice, dict):
        fn = tool_choice.get("function")
        if isinstance(fn, dict) and fn.get("name"):
            forced_tool_name = str(fn["name"])
    require_tool = tool_choice == "required" or bool(forced_tool_name)

    sections: list[str] = [
        "You are operating strictly as a stateless chat-completions inference engine.",
        "CRITICAL RULE: NEVER invoke any CLI built-in host tools (such as run_command, read_file, write_file, edit_file, search_web, invoke_subagent, or ask_question). Answer or emit function calls purely from the provided conversation.",
    ]

    schema: dict | None = None
    if declared_tools:
        schema = TOOL_ENVELOPE_SCHEMA
        sections.append(
            "Respond ONLY via the structured JSON output matching the schema `{\"content\": string, \"tool_calls\": [{\"name\": string, \"arguments_json\": string}]}`:\n"
            "- When you want to call one or more functions from <available_functions>, add each call to `tool_calls` with its exact `name` and a valid JSON object string in `arguments_json` (for example `\"{\\\"query\\\":\\\"test\\\"}\"`), and keep `content` empty or brief.\n"
            "- When no function call is needed, set `tool_calls` to `[]` and put your full assistant reply in `content`."
        )
        if forced_tool_name:
            sections.append(f"You MUST include at least one call to `{forced_tool_name}` in `tool_calls`.")
        elif require_tool:
            sections.append("You MUST include at least one function call in `tool_calls`.")
        sections.append(
            "<available_functions>\n"
            + json.dumps(declared_tools, ensure_ascii=False)
            + "\n</available_functions>"
        )

    system_chunks: list[str] = []
    convo_chunks: list[str] = []
    for msg in messages or ():
        if not isinstance(msg, dict):
            continue
        role = str(msg.get("role") or "user").lower()
        text = _extract_content_text(msg.get("content"))
        if role in {"system", "developer"}:
            if text.strip():
                system_chunks.append(text.strip())
            continue
        if role == "assistant":
            tcalls = msg.get("tool_calls") or []
            rendered_calls: list[dict] = []
            for tc in tcalls:
                if not isinstance(tc, dict):
                    continue
                fn = tc.get("function") or {}
                rendered_calls.append(
                    {
                        "id": tc.get("id") or "",
                        "name": fn.get("name") or tc.get("name") or "",
                        "arguments": fn.get("arguments") or "{}",
                    }
                )
            block = f"[ASSISTANT]: {text}" if text else "[ASSISTANT]:"
            if rendered_calls:
                block += "\n<assistant_tool_calls>\n" + json.dumps(rendered_calls, ensure_ascii=False) + "\n</assistant_tool_calls>"
            convo_chunks.append(block)
        elif role == "tool":
            tc_id = str(msg.get("tool_call_id") or "")
            tc_name = str(msg.get("name") or "")
            convo_chunks.append(f"[TOOL_RESULT name={tc_name!r} id={tc_id!r}]:\n{text}")
        else:
            convo_chunks.append(f"[USER]:\n{text}")

    if system_chunks:
        sections.append("<system_instructions>\n" + "\n\n".join(system_chunks) + "\n</system_instructions>")

    footer_sections: list[str] = []
    if not declared_tools:
        footer_sections.append("Write ONLY the assistant's direct response to the latest turn in <conversation>, with no meta-commentary.")

    fixed_overhead = sum(len(s.encode("utf-8")) for s in (*sections, *footer_sections)) + 512
    convo_budget = max(32_000, MAX_PROMPT_UTF8_BYTES - fixed_overhead)
    full_convo = "\n\n".join(convo_chunks)
    if len(full_convo.encode("utf-8")) > convo_budget and len(convo_chunks) > 2:
        # Preserve the initial user/task framing plus as many recent turns/tool results as fit in budget.
        head_chunks: list[str] = []
        head_budget = min(20_000, convo_budget // 4)
        used_head = 0
        for idx, chunk in enumerate(convo_chunks[:2]):
            encoded = chunk.encode("utf-8")
            if len(encoded) > head_budget - used_head:
                clipped = encoded[: max(1024, head_budget - used_head)].decode("utf-8", errors="ignore")
                head_chunks.append(clipped + "\n...[首轮超长内容已截断]...")
                break
            head_chunks.append(chunk)
            used_head += len(encoded)

        tail_budget = max(16_000, convo_budget - used_head - 256)
        tail_chunks_rev: list[str] = []
        used_tail = 0
        for chunk in reversed(convo_chunks[len(head_chunks) :]):
            encoded = chunk.encode("utf-8")
            if used_tail + len(encoded) > tail_budget:
                if not tail_chunks_rev:
                    clipped = encoded[-tail_budget:].decode("utf-8", errors="ignore")
                    tail_chunks_rev.append("...[单条超长上下文前段已压缩]...\n" + clipped)
                break
            tail_chunks_rev.append(chunk)
            used_tail += len(encoded) + 2
        tail_chunks = list(reversed(tail_chunks_rev))
        omitted = max(0, len(convo_chunks) - len(head_chunks) - len(tail_chunks))
        marker = f"[SYSTEM_NOTE: 中间 {omitted} 条历史工具步骤已自动折叠，请结合首轮任务目标与最近进展直接继续完成剩余闭环。]"
        full_convo = "\n\n".join([*head_chunks, marker, *tail_chunks])
    elif len(full_convo.encode("utf-8")) > convo_budget:
        encoded = full_convo.encode("utf-8")
        half = convo_budget // 2
        head_s = encoded[:half].decode("utf-8", errors="ignore")
        tail_s = encoded[-half:].decode("utf-8", errors="ignore")
        full_convo = f"{head_s}\n\n...[中间较早上下文已自动压缩以适配 CLI 参数上限]...\n\n{tail_s}"

    sections.append("<conversation>\n" + full_convo + "\n</conversation>")
    sections.extend(footer_sections)

    return "\n\n".join(sections), schema, declared_names


def _coerce_arguments_json(raw_args) -> str:
    if isinstance(raw_args, dict):
        return json.dumps(raw_args, ensure_ascii=False)
    if isinstance(raw_args, str):
        stripped = raw_args.strip()
        if not stripped:
            return "{}"
        try:
            parsed = json.loads(stripped)
            if isinstance(parsed, dict):
                return json.dumps(parsed, ensure_ascii=False)
            return json.dumps({"value": parsed}, ensure_ascii=False)
        except ValueError:
            return json.dumps({"raw": stripped}, ensure_ascii=False)
    return "{}"


def parse_antigravity_cli_response(
    raw_stdout: str,
    *,
    expect_tool_envelope: bool,
    declared_names: set[str],
) -> dict:
    """Parse `agy --output-format json` stdout into `{content, tool_calls, usage}`."""
    cleaned = (raw_stdout or "").strip()
    payload: dict | None = None
    try:
        parsed = json.loads(cleaned)
        if isinstance(parsed, dict):
            payload = parsed
    except ValueError:
        for line in reversed(cleaned.splitlines()):
            line = line.strip()
            if line.startswith("{") and line.endswith("}"):
                with contextlib.suppress(ValueError):
                    candidate = json.loads(line)
                    if isinstance(candidate, dict):
                        payload = candidate
                        break

    if payload is None:
        return {
            "content": cleaned,
            "tool_calls": [],
            "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
        }

    status = str(payload.get("status") or "SUCCESS").upper()
    if status not in {"SUCCESS", "OK", "COMPLETED"}:
        err_msg = str(payload.get("error") or payload.get("response") or f"Antigravity CLI status={status}")
        raise RuntimeError(err_msg)

    raw_usage = payload.get("usage") if isinstance(payload.get("usage"), dict) else {}
    usage = {
        "prompt_tokens": int(raw_usage.get("input_tokens") or 0),
        "completion_tokens": int(raw_usage.get("output_tokens") or 0),
        "total_tokens": int(raw_usage.get("total_tokens") or 0),
    }

    if not expect_tool_envelope:
        structured = payload.get("structured_output")
        if structured is not None:
            content = json.dumps(structured, ensure_ascii=False) if not isinstance(structured, str) else structured
        else:
            content = str(payload.get("response") or "")
            if content.endswith("\n"):
                content = content[:-1]
        return {"content": content, "tool_calls": [], "usage": usage}

    envelope = payload.get("structured_output")
    if not isinstance(envelope, dict):
        resp_text = str(payload.get("response") or "").strip()
        with contextlib.suppress(ValueError):
            candidate = json.loads(resp_text)
            if isinstance(candidate, dict):
                envelope = candidate
    if not isinstance(envelope, dict):
        return {
            "content": str(payload.get("response") or "").strip(),
            "tool_calls": [],
            "usage": usage,
        }

    content = str(envelope.get("content") or "")
    tool_calls: list[dict] = []
    for raw_call in envelope.get("tool_calls") or ():
        if not isinstance(raw_call, dict):
            continue
        name = str(raw_call.get("name") or "").strip()
        if not name:
            continue
        if declared_names and name not in declared_names:
            stripped = name[5:] if name.startswith("mcp__") else name
            if stripped in declared_names:
                name = stripped
            else:
                continue
        args_json = _coerce_arguments_json(
            raw_call.get("arguments_json") if "arguments_json" in raw_call else raw_call.get("arguments")
        )
        tool_calls.append(
            {
                "id": f"call_{uuid.uuid4().hex[:16]}",
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": args_json,
                },
            }
        )
    return {"content": content, "tool_calls": tool_calls, "usage": usage}


@contextlib.contextmanager
def _agy_concurrency_slot(*, background: bool = False):
    if background:
        with _AGY_BACKGROUND_SEM:
            with _AGY_TOTAL_SEM:
                yield
    else:
        with _AGY_TOTAL_SEM:
            yield


def run_antigravity_completion(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    tool_choice=None,
    response_format: dict | None = None,
    data_dir: Path | None = None,
    timeout: float = 180.0,
    background: bool = False,
) -> dict:
    """Execute a synchronous chat completion via official `agy` CLI."""
    cli = find_antigravity_cli()
    if not cli:
        raise RuntimeError("未找到 Antigravity CLI (agy)，请先安装 agy。")

    prompt, tool_schema, declared_names = build_antigravity_prompt(
        messages,
        tools=tools,
        tool_choice=tool_choice,
    )
    expect_tool_envelope = tool_schema is not None
    effective_schema = tool_schema
    if effective_schema is None and isinstance(response_format, dict):
        rf_type = response_format.get("type")
        if rf_type == "json_schema":
            js = response_format.get("json_schema") or {}
            if isinstance(js, dict) and isinstance(js.get("schema"), dict):
                effective_schema = js["schema"]

    encoded_prompt = prompt.encode("utf-8")
    if len(encoded_prompt) > MAX_PROMPT_UTF8_BYTES + 16_000:
        head = encoded_prompt[:56_000].decode("utf-8", errors="ignore")
        tail = encoded_prompt[-56_000:].decode("utf-8", errors="ignore")
        prompt = f"{head}\n\n...[中间较早上下文已自动压缩以适配 CLI 参数上限]...\n\n{tail}"

    sandbox_dir = _empty_sandbox_dir(data_dir)
    schema_file: Path | None = None
    cmd = [
        cli,
        "-p",
        prompt,
        "--model",
        model,
        "--disable-slash-commands",
        "--sandbox",
        "--output-format",
        "json",
    ]
    if effective_schema is not None:
        schema_str = json.dumps(effective_schema, ensure_ascii=False)
        if len(schema_str.encode("utf-8")) > 8_192:
            schema_file = sandbox_dir / f"schema-{uuid.uuid4().hex}.json"
            schema_file.write_text(schema_str, encoding="utf-8")
            cmd.extend(["--json-schema", str(schema_file)])
        else:
            cmd.extend(["--json-schema", schema_str])

    try:
        with _agy_concurrency_slot(background=background):
            proc = subprocess.run(
                cmd,
                cwd=str(sandbox_dir),
                env=_agy_env(),
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=timeout,
                check=False,
            )
    finally:
        if schema_file is not None:
            with contextlib.suppress(OSError):
                schema_file.unlink()
    if proc.returncode != 0:
        detail = ANSI_ESCAPE_RE.sub("", (proc.stderr or proc.stdout or "").strip())
        raise RuntimeError(detail[:400] or f"agy exited with status {proc.returncode}")

    parsed = parse_antigravity_cli_response(
        proc.stdout,
        expect_tool_envelope=expect_tool_envelope,
        declared_names=declared_names,
    )
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:20]}"
    created = int(time.time())
    tool_calls = parsed["tool_calls"]
    content = parsed["content"]
    finish_reason = "tool_calls" if tool_calls else "stop"

    message_obj: dict = {
        "role": "assistant",
        "content": content if (content or not tool_calls) else None,
    }
    if tool_calls:
        message_obj["tool_calls"] = tool_calls

    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created,
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": message_obj,
                "finish_reason": finish_reason,
            }
        ],
        "usage": parsed["usage"],
    }


def format_sse_chunks_from_completion(completion: dict) -> bytes:
    """Convert a chat.completion payload into OpenAI-compatible SSE stream bytes."""
    cid = completion["id"]
    created = completion["created"]
    model = completion["model"]
    choice = (completion.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    finish_reason = choice.get("finish_reason") or "stop"
    content = msg.get("content")
    tool_calls = msg.get("tool_calls") or []

    events: list[str] = []
    # Initial assistant role chunk
    events.append(
        json.dumps(
            {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": None}],
            },
            ensure_ascii=False,
        )
    )
    if content:
        events.append(
            json.dumps(
                {
                    "id": cid,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{"index": 0, "delta": {"content": content}, "finish_reason": None}],
                },
                ensure_ascii=False,
            )
        )
    if tool_calls:
        streamed_calls = [
            {
                "index": idx,
                "id": tc["id"],
                "type": "function",
                "function": {
                    "name": tc["function"]["name"],
                    "arguments": tc["function"]["arguments"],
                },
            }
            for idx, tc in enumerate(tool_calls)
        ]
        events.append(
            json.dumps(
                {
                    "id": cid,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model,
                    "choices": [{"index": 0, "delta": {"tool_calls": streamed_calls}, "finish_reason": None}],
                },
                ensure_ascii=False,
            )
        )
    events.append(
        json.dumps(
            {
                "id": cid,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": finish_reason}],
                "usage": completion.get("usage") or {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            },
            ensure_ascii=False,
        )
    )
    body = "".join(f"data: {item}\n\n" for item in events) + "data: [DONE]\n\n"
    return body.encode("utf-8")


async def run_antigravity_completion_async(
    *,
    model: str,
    messages: list[dict],
    tools: list[dict] | None = None,
    tool_choice=None,
    response_format: dict | None = None,
    data_dir: Path | None = None,
    timeout: float = 180.0,
    background: bool = False,
) -> dict:
    """Async non-blocking wrapper around `run_antigravity_completion`."""
    return await asyncio.to_thread(
        run_antigravity_completion,
        model=model,
        messages=messages,
        tools=tools,
        tool_choice=tool_choice,
        response_format=response_format,
        data_dir=data_dir,
        timeout=timeout,
        background=background,
    )
