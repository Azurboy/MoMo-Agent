"""Provider service reminder classification and durable state (quota, auth, rate-limit).

Only app-owned reminder copy crosses the UI boundary — raw SDK errors, URLs,
headers, tokens, and stack traces never leave the local runtime process.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import uuid

PROVIDER_NOTICE_REL = "runtime/provider-notice.json"
NOTICE_COALESCE_SECONDS = 120.0
NOTICE_MAX_AGE_SECONDS = 43200.0  # 12 hours

_PROVIDER_CANONICAL = {
    "codex": "openai-codex",
    "openai-codex": "openai-codex",
    "claude": "anthropic",
    "anthropic": "anthropic",
    "antigravity": "antigravity",
    "agy": "antigravity",
    "custom": "custom",
    "openai": "custom",
    "api": "custom",
}

_PROVIDER_LABELS = {
    "openai-codex": "Codex",
    "anthropic": "Claude",
    "antigravity": "Antigravity",
    "custom": "自定义 API",
}

_NON_PROVIDER_NOISE = (
    "gateway_restarted",
    "dsh_startup_timeout",
    "prepare command failed",
    "preparefailed",
    "launch authorization changed",
    "the ticket ended",
    "dsh-superagent is stopping",
    "processing is paused",
    "connection refused",
    "operation_conflict",
)

_QUOTA_PATTERNS = (
    r"\binsufficient[_\s-]*quota\b",
    r"\bbilling[_\s-]*hard[_\s-]*limit",
    r"\bquota[_\s-]*exceeded\b",
    r"\bexceeded\s+your\s+current\s+quota\b",
    r"\busage[_\s-]*limit(?:[_\s-]*reached)?\b",
    r"\bhit\s+your\s+(?:usage\s+)?limit\b",
    r"\breached\s+(?:your|the)\s+(?:usage|plan|model|daily|weekly|monthly|quota)\s+limit\b",
    r"\bexhausted\s+your\s+(?:capacity|quota)\b",
    r"\bno\s+capacity\s+available\b",
    r"\bcredit\s+balance\s+is\s+too\s+low\b",
    r"\binsufficient[_\s-]*(?:balance|credits?|funds)\b",
    r"\bbudget[_\s-]*exceeded\b",
    r"\bbudget\s+has\s+been\s+exceeded\b",
    r"\bover\s+its\s+model\s+budget\b",
    r"\bout\s+of\s+(?:credits?|quota)\b",
    r"\bpayment[_\s-]*required\b",
    r"额度(?:不足|已用完|耗尽|用尽|超限)",
    r"余额不足",
    r"配额(?:不足|已用完|超限)",
    r"用量已达上限",
    r"欠费",
)

_AUTH_PATTERNS = (
    r"\binvalid[_\s-]*api[_\s-]*key\b",
    r"\bapi\s+key\s+not\s+valid\b",
    r"\binvalid\s+x-api-key\b",
    r"\bauthentication[_\s-]*(?:error|failed)\b",
    r"\bunauthenticated\b",
    r"\btoken[_\s-]*expired\b",
    r"\boauth\s+token\s+has\s+expired\b",
    r"\brefresh[_\s-]*token[_\s-]*(?:expired|invalid|revoked)\b",
    r"\binvalid[_\s-]*grant\b",
    r"\bnot\s+logged\s+in\b",
    r"\bplease\s+(?:log\s*in|sign\s*in)\b",
    r"\blogin\s+required\b",
    r"\bre-?authenticate\b",
    r"\baccount[_\s-]*deactivated\b",
    r"请先(?:登录|使用.*登录)",
    r"登录(?:已失效|已过期|状态失效)",
)

_RATE_LIMIT_PATTERNS = (
    r"\brate[_\s-]*limit(?:[_\s-]*(?:exceeded|error))?\b",
    r"\btoo\s+many\s+requests\b",
    r"\boverloaded[_\s-]*error\b",
    r"\bmodel[_\s-]*overloaded\b",
    r"\btemporarily\s+rate-limited\b",
    r"\bresource[_\s-]*exhausted\b",
    r"请求过于频繁",
    r"触发限流",
)

_HTTP_STATUS_RE = re.compile(
    r"(?:\bstatus(?:[_\s-]*code)?\s*[:=]\s*|\bHTTP(?:/\d(?:\.\d)?)?\s+|\bError\s+code:\s*)(401|402|403|429|529)\b",
    re.IGNORECASE,
)


def canonical_provider(provider: str | None) -> str:
    raw = str(provider or "").strip().lower()
    return _PROVIDER_CANONICAL.get(raw, raw or "unknown")


def provider_display_label(provider: str | None) -> str:
    canon = canonical_provider(provider)
    return _PROVIDER_LABELS.get(canon, "当前模型服务")


def _extract_error_signals(raw_error: object, explicit_status: int | None) -> tuple[str, int | None]:
    parts: list[str] = []
    status = explicit_status if isinstance(explicit_status, int) else None

    if raw_error is not None:
        parts.append(str(raw_error))
        for attr in ("status_code", "status"):
            val = getattr(raw_error, attr, None)
            if status is None and isinstance(val, int):
                status = val
        for attr in ("code", "type", "failure_reason"):
            val = getattr(raw_error, attr, None)
            if isinstance(val, str) and val.strip():
                parts.append(val.strip())
        body = getattr(raw_error, "body", None)
        if isinstance(body, (dict, list)):
            with contextlib.suppress(Exception):
                parts.append(json.dumps(body, ensure_ascii=False))
        elif isinstance(body, str) and body.strip():
            parts.append(body.strip())

    combined = "\n".join(parts)[:16384]
    if status is None and combined:
        m = _HTTP_STATUS_RE.search(combined)
        if m:
            status = int(m.group(1))
    return combined, status


def build_provider_notice(kind: str, *, provider: str = "", now: float | None = None, notice_id: str | None = None) -> dict:
    ts = float(now if now is not None else time.time())
    canon = canonical_provider(provider)
    label = provider_display_label(canon)
    has_named_provider = label != "当前模型服务"

    if kind == "quota":
        title = f"{label} 当前额度已用完" if has_named_provider else "当前模型服务额度已用完"
        message = (
            f"{label} 的可用额度或本周期用量已达上限。你的对话和任务记录都已保留，"
            "可以在「设置 → 模型」中切换到其他模型服务继续使用，或等待额度恢复后再试。"
        )
        short_error = f"{label} 当前额度已用完，可在「设置 → 模型」切换其他服务，或等待额度恢复后再试。"
    elif kind == "auth":
        if canon == "custom":
            title = "自定义 API 密钥需要更新"
            message = (
                "当前自定义 API 的密钥或授权不可用。你的对话和任务记录都已保留，"
                "请前往「设置 → 模型」检查 API 密钥，或切换到其他模型服务。"
            )
            short_error = "自定义 API 密钥不可用，请前往「设置 → 模型」更新或切换服务。"
        else:
            title = f"{label} 需要重新登录" if has_named_provider else "模型服务需要重新登录"
            message = (
                f"{label} 的登录授权已过期或当前账号不可用。你的对话和任务记录都已保留，"
                "请前往「设置 → 模型」重新登录，或切换到其他模型服务继续使用。"
            )
            short_error = f"{label} 登录状态已过期，请前往「设置 → 模型」重新登录或切换服务。"
    elif kind == "rate_limit":
        title = f"{label} 当前请求较忙" if has_named_provider else "当前模型服务请求较忙"
        message = (
            f"{label} 触发了短时速率限制或服务正忙。你的对话和任务记录都已保留，"
            "稍等片刻即可恢复，也可以在「设置 → 模型」中临时切换其他模型服务。"
        )
        short_error = f"{label} 当前请求较忙，请稍候再试或在「设置 → 模型」切换其他服务。"
    else:
        raise ValueError(f"Unsupported provider notice kind: {kind}")

    return {
        "id": notice_id or f"pnotice-{uuid.uuid4().hex[:16]}",
        "kind": kind,
        "provider": canon,
        "provider_label": label,
        "title": title,
        "message": message,
        "short_error": short_error,
        "created_at": ts,
        "updated_at": ts,
    }


def classify_provider_issue(
    raw_error: object,
    *,
    provider: str = "",
    status_code: int | None = None,
    now: float | None = None,
) -> dict | None:
    """Classify an LLM/provider failure into an app-owned reminder dict, or None if not a provider limit/auth issue."""
    if raw_error is None and status_code is None:
        return None

    text, status = _extract_error_signals(raw_error, status_code)
    lowered = text.lower().strip()
    if not lowered and status is None:
        return None

    if any(noise in lowered for noise in _NON_PROVIDER_NOISE):
        return None

    # Infer provider from error text if caller didn't pass a specific one.
    canon = canonical_provider(provider)
    if canon == "unknown":
        if "antigravity" in lowered or "agy" in lowered or "googleapis" in lowered:
            canon = "antigravity"
        elif "anthropic" in lowered or "claude" in lowered:
            canon = "anthropic"
        elif "codex" in lowered or "chatgpt" in lowered:
            canon = "openai-codex"

    # 1. Quota / billing / usage cap exhaustion (check before generic 429 rate-limit!)
    if status == 402 or any(re.search(pat, text, re.IGNORECASE) for pat in _QUOTA_PATTERNS):
        return build_provider_notice("quota", provider=canon, now=now)

    # Antigravity CLI surfaces quota limits as RESOURCE_EXHAUSTED / 429 on the selected model.
    if canon == "antigravity" and re.search(r"\bresource[_\s-]*exhausted\b", text, re.IGNORECASE):
        return build_provider_notice("quota", provider=canon, now=now)

    # 2. Authentication / login expiration
    if status in (401, 403) or any(re.search(pat, text, re.IGNORECASE) for pat in _AUTH_PATTERNS):
        # Guard against local OS/tool "Permission denied" unrelated to API auth when status is absent.
        if status not in (401, 403) and re.search(r"\berrno\s+13\b|\beacces\b|\boperation not permitted\b", text, re.IGNORECASE):
            return None
        return build_provider_notice("auth", provider=canon, now=now)

    # 3. Short-term rate limit / overloaded
    if status in (429, 529) or any(re.search(pat, text, re.IGNORECASE) for pat in _RATE_LIMIT_PATTERNS):
        return build_provider_notice("rate_limit", provider=canon, now=now)

    return None


def _notice_path(data_dir: Path) -> Path:
    return Path(data_dir) / PROVIDER_NOTICE_REL


def _write_private_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=".provider-notice-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    except Exception:
        with contextlib.suppress(OSError):
            os.unlink(tmp_name)
        raise


def read_provider_notice(data_dir: Path, *, now: float | None = None) -> dict | None:
    path = _notice_path(data_dir)
    if not path.is_file():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    required = ("id", "kind", "provider", "provider_label", "title", "message", "short_error", "created_at")
    if not all(isinstance(raw.get(k), str) and raw[k] for k in required[:-1]):
        return None
    try:
        created_at = float(raw["created_at"])
        updated_at = float(raw.get("updated_at", created_at))
    except (TypeError, ValueError):
        return None
    ref_now = float(now if now is not None else time.time())
    if ref_now - updated_at > NOTICE_MAX_AGE_SECONDS:
        clear_provider_notice(data_dir)
        return None
    return {
        "id": raw["id"],
        "kind": raw["kind"],
        "provider": raw["provider"],
        "provider_label": raw["provider_label"],
        "title": raw["title"],
        "message": raw["message"],
        "short_error": raw["short_error"],
        "created_at": created_at,
        "updated_at": updated_at,
    }


def record_provider_issue(
    data_dir: Path,
    raw_error: object,
    *,
    provider: str = "",
    status_code: int | None = None,
    coalesce_seconds: float = NOTICE_COALESCE_SECONDS,
    now: float | None = None,
) -> dict | None:
    ref_now = float(now if now is not None else time.time())
    classified = classify_provider_issue(raw_error, provider=provider, status_code=status_code, now=ref_now)
    if classified is None:
        return None

    existing = read_provider_notice(data_dir, now=ref_now)
    if (
        existing is not None
        and existing["provider"] == classified["provider"]
        and existing["kind"] == classified["kind"]
        and (ref_now - float(existing["updated_at"])) <= coalesce_seconds
    ):
        # Coalesce rapid retries from the same failure burst under one notice ID
        # so acknowledging "知道了" is not immediately spammed by an in-flight retry.
        classified["id"] = existing["id"]
        classified["created_at"] = existing["created_at"]
        classified["updated_at"] = ref_now

    with contextlib.suppress(OSError):
        _write_private_json(_notice_path(data_dir), classified)
    return classified


def clear_provider_notice(data_dir: Path, *, provider: str | None = None) -> bool:
    path = _notice_path(data_dir)
    if not path.is_file():
        return False
    if provider is not None:
        existing = read_provider_notice(data_dir)
        canon = canonical_provider(provider)
        if existing is not None and canon != "unknown" and existing["provider"] not in (canon, "unknown"):
            return False
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return False
