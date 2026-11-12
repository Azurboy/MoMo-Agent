"""DeepSeek Harness runtime settings for MoMo Agent."""
from __future__ import annotations

import json
import os
from pathlib import Path

PROACTIVE_MODES = ("auto", "observe", "off")
DEFAULT_ENGINE = "superagent"
DEFAULT_PROACTIVE_MODE = "auto"


def _atomic_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def engine_config_path(data: Path) -> Path:
    return Path(data) / "runtime/engine.json"


def read_engine_config(data: Path) -> dict[str, str]:
    """Read runtime engine selection without mutating unconfigured directories."""
    path = engine_config_path(data)
    if not path.is_file():
        return {"engine": DEFAULT_ENGINE, "proactive_mode": DEFAULT_PROACTIVE_MODE}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {"engine": DEFAULT_ENGINE, "proactive_mode": DEFAULT_PROACTIVE_MODE}
    if not isinstance(raw, dict):
        return {"engine": DEFAULT_ENGINE, "proactive_mode": DEFAULT_PROACTIVE_MODE}
    proactive = raw.get("proactive_mode") if raw.get("proactive_mode") in PROACTIVE_MODES else DEFAULT_PROACTIVE_MODE
    return {"engine": DEFAULT_ENGINE, "proactive_mode": proactive}


def write_engine_config(
    data: Path,
    *,
    engine: str | None = None,
    proactive_mode: str | None = None,
) -> dict[str, str]:
    """Persist runtime engine and proactive evaluation mode atomically (mode 0600)."""
    current = read_engine_config(data)
    if engine is not None and engine != DEFAULT_ENGINE:
        raise ValueError(f"Unsupported runtime engine: {engine!r}")
    if proactive_mode is not None:
        if proactive_mode not in PROACTIVE_MODES:
            raise ValueError(f"Unsupported proactive mode: {proactive_mode!r} (expected one of {PROACTIVE_MODES})")
        current["proactive_mode"] = proactive_mode
    _atomic_private(engine_config_path(data), json.dumps(current, ensure_ascii=False, indent=2) + "\n")
    return current
