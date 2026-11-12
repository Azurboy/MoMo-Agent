"""Unified shared Markdown memory & living notebook store for MoMo Agent.

All engines (DeepSeek SuperAgent Orchestrator & Workers, Dream idle-time consolidation,
momo-cli, ContextServer REST API, and macOS/iOS clients) share this single pure-Markdown
file store (`memories/USER.md`, `memories/MEMORY.md`, `memories/BRIEFING.md`,
`memories/journal/*.md`, `memories/people/*.md`, `memories/topics/*.md`).
"""
from __future__ import annotations

from contextlib import contextmanager, suppress
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time
from typing import Any

from context_store import Conflict

ENTRY_DELIMITER = "\n§\n"
MEMORY_BLOCK_HEADERS = {
    "memory": "MEMORY (your personal notes)",
    "user": "USER PROFILE (who the user is)",
}
PATCH_DROP_HINT = (
    "To drop text inside an entry, patch a longer span that contains it; "
    "'remove' deletes the whole entry."
)

NOTEBOOK_KINDS = {
    "briefing": ("BRIEFING.md", None),
    "project": (None, "projects"),
    "journal": (None, "journal"),
    "person": (None, "people"),
    "topic": (None, "topics"),
    "note": (None, None),
}
_STANDARD_ROOT_FOLDERS = {
    "projects": "project",
    "project": "project",
    "journal": "journal",
    "journals": "journal",
    "people": "person",
    "person": "person",
    "topics": "topic",
    "topic": "topic",
}
_CANONICAL_FOLDER_FOR_KIND = {
    "project": "projects",
    "journal": "journal",
    "person": "people",
    "topic": "topics",
}
_MAX_NOTEBOOK_DEPTH = 6
_SLUG_RE = re.compile(r"[^\w\u4e00-\u9fff.-]+", re.UNICODE)
_MATCH_FOLD = str.maketrans({
    **dict.fromkeys("\"`\u2018\u2019\u201a\u201b\u201c\u201d\u201e\u201f", "'"),
    **dict.fromkeys("\u2010\u2011\u2012\u2013\u2014\u2015\u2212", "-"),
})

MEMORY_SCHEMA = {
    "name": "memory",
    "description": (
        "Save durable facts to persistent shared Markdown memory (`MEMORY.md` and `USER.md`) "
        "that survive across sessions and are injected into every future turn.\n\n"
        "HOW: make ALL your changes to one target in ONE call via an 'operations' array "
        "(each item: {action, content?, old_text?}). The batch applies atomically and the char "
        "limit is checked only on the FINAL result — so a single call can remove/patch stale "
        "entries to free room AND add new ones. Use bare action/content/old_text fields only "
        "for a single change.\n\n"
        "TARGETS: 'user' = who the user is (name, role, preferences, communication style). "
        "'memory' = shared core index (active goals, key conventions, cross-session anchors). "
        "Put detailed daily logs, project hierarchies, person profiles, and domain notes into the `notebook` tool "
        "(supporting multi-level folders like `projects/<project>/<doc>.md`, `journal/YYYY-MM/YYYY-MM-DD.md`, `people/...`, or custom directories) rather than overflowing `MEMORY.md`."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["add", "patch", "remove"],
                "description": "The action to perform (single-op shape). Omit when using 'operations'.",
            },
            "target": {
                "type": "string",
                "enum": ["memory", "user"],
                "description": "Which memory store: 'memory' for shared notes, 'user' for user profile.",
            },
            "content": {
                "type": "string",
                "description": "Required for 'add' and 'patch'. Alias: 'new_text'.",
            },
            "old_text": {
                "type": "string",
                "description": "Required for 'patch' and 'remove': unique substring from the target entry.",
            },
            "new_text": {
                "type": "string",
                "description": "Alias for 'content'.",
            },
            "operations": {
                "type": "array",
                "description": "Batch of {action, content?, old_text?} applied atomically against the final char budget.",
                "items": {
                    "type": "object",
                    "properties": {
                        "action": {"type": "string", "enum": ["add", "patch", "remove"]},
                        "content": {"type": "string"},
                        "new_text": {"type": "string"},
                        "old_text": {"type": "string"},
                    },
                    "required": ["action"],
                    "additionalProperties": False,
                },
            },
        },
        "required": ["target"],
    },
}


def _sanitize_path_segment(raw: str, *, strip_md: bool = False) -> str:
    piece = str(raw or "").strip()
    if strip_md and piece.lower().endswith(".md"):
        piece = piece[:-3].strip()
    if not piece or piece in {".", ".."} or ".." in piece or "\\" in piece or "\x00" in piece:
        raise ValueError("Invalid Markdown path segment")
    cleaned = _SLUG_RE.sub("-", piece).strip("-.")
    if not cleaned or cleaned.startswith(".") or len(cleaned.encode("utf-8")) > 180:
        raise ValueError("Invalid Markdown path segment")
    return cleaned


def sanitize_notebook_slug(raw: str) -> str:
    text = str(raw or "").strip().strip("/")
    if not text or "\\" in text or ".." in text:
        raise ValueError("Invalid Markdown note slug")
    parts = [p for p in text.split("/") if p.strip()]
    if not parts or len(parts) > _MAX_NOTEBOOK_DEPTH:
        raise ValueError("Invalid Markdown note slug")
    sanitized = [
        _sanitize_path_segment(part, strip_md=(idx == len(parts) - 1))
        for idx, part in enumerate(parts)
    ]
    return "/".join(sanitized)


def _atomic_write_markdown(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def _normalize_for_match(text: str) -> str:
    return " ".join(str(text).replace("\\n", " ").translate(_MATCH_FOLD).split())


def _substring_matches(entries: list[str], old_text: str) -> list[int]:
    if exact := [i for i, e in enumerate(entries) if old_text in e]:
        return exact
    needle = _normalize_for_match(old_text)
    if not any(c.isalnum() for c in needle):
        return []
    return [i for i, e in enumerate(entries) if needle in _normalize_for_match(e)]


def _find_unique_match(entries: list[str], old_text: str) -> tuple[int | None, bool]:
    exact = [i for i, e in enumerate(entries) if e == old_text]
    matches = exact or _substring_matches(entries, old_text)
    if len({entries[i] for i in matches}) > 1:
        return None, True
    return (matches[0] if matches else None), False


def _no_match_error(entries: list[str], old_text: str, verb: str, **extra) -> dict[str, Any]:
    def _words(t: str) -> set[str]:
        return set(re.findall(r"\w+", t.lower()))

    words = _words(old_text)
    scored = sorted(
        ((len(words & _words(e)) / len(words), i) for i, e in enumerate(entries)) if words else [],
        key=lambda p: (-p[0], p[1]),
    )
    closest = [entries[i] for score, i in scored[:3] if score >= 0.3]
    hint = " old_text must come from ONE entry ('§' separates entries); use one op per entry." if "§" in old_text else ""
    return {
        "success": False,
        "error": (
            f"No entry matched '{old_text}'.{hint} Retry the {verb} with old_text copied verbatim "
            f"from the intended entry" + (" (closest_entries below)." if closest else ".")
        ),
        **({"closest_entries": closest} if closest else {}),
        **extra,
    }


def _span_occurrences(text: str, span: str) -> int:
    return sum(text.startswith(span, i) for i in range(len(text) - len(span) + 1))


def _patch_entry(entry: str, old_text: str, new_text: str) -> tuple[str | None, str]:
    if (count := _span_occurrences(entry, old_text)) > 1:
        return None, (
            f"'{old_text}' appears {count} times in the matched entry, and patch edits one span. "
            "Include more surrounding text so old_text occurs once."
        )
    patched = entry.replace(old_text, new_text, 1)
    if patched == entry:
        return None, f"Patch is a no-op: '{old_text}' -> '{new_text}' leaves the entry unchanged."
    return patched, ""


class MoMoMemoryStore:
    """Bounded file-backed Markdown memory store (`MEMORY.md` and `USER.md`) with atomic locking."""

    _MAX_CONSOLIDATION_FAILURES_PER_TURN = 3

    def __init__(
        self,
        memories_dir: Path,
        memory_char_limit: int = 3600,
        user_char_limit: int = 1800,
        *,
        memory_enabled: bool = True,
        user_profile_enabled: bool = True,
    ):
        self.memories_dir = Path(memories_dir)
        self.memory_entries: list[str] = []
        self.user_entries: list[str] = []
        self.memory_char_limit = memory_char_limit
        self.user_char_limit = user_char_limit
        self.memory_enabled = memory_enabled
        self.user_profile_enabled = user_profile_enabled
        self._system_prompt_snapshot: dict[str, str] = {"memory": "", "user": ""}
        self._consolidation_failures = 0

    def target_enabled(self, target: str) -> bool:
        return self.user_profile_enabled if target == "user" else self.memory_enabled

    def _path_for(self, target: str) -> Path:
        return self.memories_dir / ("USER.md" if target == "user" else "MEMORY.md")

    def _entries_for(self, target: str) -> list[str]:
        return self.user_entries if target == "user" else self.memory_entries

    def _set_entries(self, target: str, entries: list[str]) -> None:
        if target == "user":
            self.user_entries = entries
        else:
            self.memory_entries = entries

    def _char_count(self, target: str) -> int:
        return len(ENTRY_DELIMITER.join(self._entries_for(target)))

    def _char_limit(self, target: str) -> int:
        return self.user_char_limit if target == "user" else self.memory_char_limit

    def _usage(self, target: str) -> str:
        return f"{self._char_count(target):,}/{self._char_limit(target):,}"

    def _usage_pct(self, target: str, current: int) -> str:
        limit = self._char_limit(target)
        return f"{min(100, int((current / limit) * 100)) if limit > 0 else 0}% — {current:,}/{limit:,} chars"

    def _render_block(self, target: str, entries: list[str]) -> str:
        if not entries:
            return ""
        content, sep = ENTRY_DELIMITER.join(entries), "═" * 46
        title = MEMORY_BLOCK_HEADERS["user" if target == "user" else "memory"]
        return f"{sep}\n{title} [{self._usage_pct(target, len(content))}]\n{sep}\n{content}"

    def format_for_system_prompt(self, target: str) -> str | None:
        return self._system_prompt_snapshot.get(target, "") or None

    @staticmethod
    def _read_raw_checked(path: Path) -> tuple[str, bool]:
        if not path.exists():
            return "", True
        try:
            return path.read_text(encoding="utf-8-sig"), True
        except (OSError, UnicodeDecodeError):
            return "", False

    @staticmethod
    def _parse_entries(raw: str) -> list[str]:
        return [e for e in (x.strip() for x in raw.split(ENTRY_DELIMITER)) if e]

    def load_from_disk(self) -> None:
        self.memories_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        for target in ("memory", "user"):
            path = self._path_for(target)
            raw, read_ok = self._read_raw_checked(path)
            if not read_ok:
                raise UnicodeDecodeError("utf-8", b"", 0, 1, f"Unable to read {path}")
            entries = list(dict.fromkeys(self._parse_entries(raw)))
            self._set_entries(target, entries)
            self._system_prompt_snapshot[target] = self._render_block(target, entries)

    @contextmanager
    def _file_lock(self, path: Path):
        self.memories_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_path = path.with_suffix(path.suffix + ".lock")
        raw_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            if hasattr(os, "fchmod"):
                os.fchmod(raw_fd, 0o600)
            fd = os.fdopen(raw_fd, "r+", encoding="utf-8")
        except Exception:
            os.close(raw_fd)
            raise
        with fd:
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                yield
            finally:
                with suppress(OSError):
                    fcntl.flock(fd, fcntl.LOCK_UN)

    def _consolidation_failure(self, response: dict[str, Any]) -> dict[str, Any]:
        self._consolidation_failures += 1
        if self._consolidation_failures <= self._MAX_CONSOLIDATION_FAILURES_PER_TURN:
            return response
        return {
            "success": False,
            "done": True,
            "error": (
                f"Memory consolidation failed {self._consolidation_failures} times this turn. "
                "Stop retrying memory calls — leave memory unchanged for now."
            ),
        }

    def _success_response(self, target: str, message: str | None = None, **extra) -> dict[str, Any]:
        self._consolidation_failures = 0
        return {
            "success": True,
            "done": True,
            "target": target,
            "usage": self._usage_pct(target, self._char_count(target)),
            "entry_count": len(self._entries_for(target)),
            **({"message": message} if message else {}),
            **extra,
            "note": "Write saved. This update is complete — do not repeat it.",
        }

    def _mutate(self, target: str, mutate) -> dict[str, Any]:
        path = self._path_for(target)
        with self._file_lock(path):
            raw, read_ok = self._read_raw_checked(path)
            if not read_ok:
                return {"success": False, "error": f"Refusing to write {path.name}: file could not be read."}
            self._set_entries(target, list(dict.fromkeys(self._parse_entries(raw))))
            result = mutate(self._entries_for(target), self._char_limit(target))
            if isinstance(result, dict):
                return result
            self._set_entries(target, result[0])
            _atomic_write_markdown(path, ENTRY_DELIMITER.join(result[0]))
            extra_fields = result[2] if len(result) > 2 else {}
            return self._success_response(target, result[1], **extra_fields)

    def add(self, target: str, content: str) -> dict[str, Any]:
        content = (content or "").strip()
        if not content:
            return {"success": False, "error": "Content cannot be empty."}

        def _add(entries: list[str], limit: int):
            if content in entries:
                return self._success_response(target, "Entry already exists (no duplicate added).")
            new_total = len(ENTRY_DELIMITER.join(entries + [content]))
            if new_total > limit:
                return self._consolidation_failure({
                    "success": False,
                    "error": (
                        f"Memory at {self._char_count(target):,}/{limit:,} chars; adding this entry ({len(content)} chars) "
                        f"would exceed the limit by {new_total - limit:,} chars. Retry as ONE 'operations' batch that "
                        f"removes or shortens stale entries from current_entries below, or write detailed notes to `notebook`."
                    ),
                    "current_entries": entries,
                    "usage": self._usage(target),
                })
            return entries + [content], "Entry added."

        return self._mutate(target, _add)

    def _locate(self, entries: list[str], old_text: str, verb: str, matched_entry: str | None = None):
        if matched_entry is not None:
            return entries.index(matched_entry) if matched_entry in entries else {
                "success": False,
                "error": f"Entry changed since it was staged: '{matched_entry}' is no longer in memory.",
            }
        idx, ambiguous = _find_unique_match(entries, old_text)
        if ambiguous:
            return {
                "success": False,
                "error": f"Multiple entries matched '{old_text}'. Be more specific.",
                "matches": [entries[i][:80] for i in _substring_matches(entries, old_text)],
            }
        if idx is None:
            return self._consolidation_failure(_no_match_error(entries, old_text, verb, current_entries=entries))
        return idx

    def patch(self, target: str, old_text: str, new_text: str, matched_entry: str | None = None) -> dict[str, Any]:
        if not (old_text or "").strip():
            return {"success": False, "error": "old_text cannot be empty."}
        if new_text is None or not str(new_text).strip():
            return {"success": False, "error": f"new_text cannot be empty. {PATCH_DROP_HINT}"}

        def _apply(entries: list[str], limit: int):
            idx = self._locate(entries, old_text, "patch", matched_entry)
            if isinstance(idx, dict):
                return idx
            before = entries[idx]
            after, err = _patch_entry(before, old_text, str(new_text))
            if after is None:
                return {"success": False, "error": err}
            patched = entries[:idx] + [after] + entries[idx + 1:]
            new_total = len(ENTRY_DELIMITER.join(patched))
            if new_total > limit:
                return self._consolidation_failure({
                    "success": False,
                    "error": f"Patch would put memory at {new_total:,}/{limit:,} chars.",
                    "current_entries": entries,
                    "usage": self._usage(target),
                })
            return patched, "Entry patched.", {"patched_entry_before": before, "patched_entry_after": after}

        return self._mutate(target, _apply)

    def replace(self, target: str, old_text: str, new_content: str, matched_entry: str | None = None) -> dict[str, Any]:
        new_content = (new_content or "").strip()
        if not (old_text or "").strip():
            return {"success": False, "error": "old_text cannot be empty."}
        if not new_content:
            return {"success": False, "error": "new_content cannot be empty. Use 'remove' to delete entries."}
        return self._edit(target, old_text.strip(), new_content, matched_entry)

    def remove(self, target: str, old_text: str, matched_entry: str | None = None) -> dict[str, Any]:
        if not (old_text or "").strip():
            return {"success": False, "error": "old_text cannot be empty."}
        return self._edit(target, old_text.strip(), None, matched_entry)

    def _edit(self, target: str, old_text: str, new_content: str | None, matched_entry: str | None = None) -> dict[str, Any]:
        def _apply(entries: list[str], limit: int):
            idx = self._locate(entries, old_text, "replace" if new_content else "remove", matched_entry)
            if isinstance(idx, dict):
                return idx
            replaced = entries[:idx] + ([] if new_content is None else [new_content]) + entries[idx + 1:]
            if new_content is None:
                return replaced, "Entry removed.", {"removed_entry": entries[idx]}
            new_total = len(ENTRY_DELIMITER.join(replaced))
            if new_total > limit:
                return self._consolidation_failure({
                    "success": False,
                    "error": f"Replacement would put memory at {new_total:,}/{limit:,} chars.",
                    "current_entries": entries,
                    "usage": self._usage(target),
                })
            return replaced, "Entry replaced.", {"replaced_entry": entries[idx]}

        return self._mutate(target, _apply)

    def apply_batch(self, target: str, operations: list[dict[str, Any]]) -> dict[str, Any]:
        if not operations or not isinstance(operations, list):
            return {"success": False, "error": "operations list is empty."}
        ops = [op or {} for op in operations]

        def _apply(entries: list[str], limit: int):
            working = list(entries)
            for i, op in enumerate(ops, 1):
                act = op.get("action")
                content = op.get("content") or op.get("new_text") or ""
                old_text = op.get("old_text") or ""
                if act != "patch":
                    content, old_text = str(content).strip(), str(old_text).strip()
                pos = f"Operation {i} ({act or 'unknown'})"
                if act == "add":
                    if not content:
                        return self._consolidation_failure({"success": False, "error": f"{pos}: content is required.", "usage": self._usage(target)})
                    if content not in working:
                        working.append(content)
                elif act in ("remove", "patch", "replace"):
                    if not old_text.strip():
                        return self._consolidation_failure({"success": False, "error": f"{pos}: old_text is required.", "usage": self._usage(target)})
                    idx, ambiguous = _find_unique_match(working, old_text)
                    if ambiguous:
                        return self._consolidation_failure({"success": False, "error": f"{pos}: '{old_text}' matched multiple entries.", "usage": self._usage(target)})
                    if idx is None:
                        miss = _no_match_error(working, old_text, act)
                        return self._consolidation_failure({
                            "success": False,
                            "error": f"{pos}: {miss['error']} No operations were applied (batch is all-or-nothing).",
                            "usage": self._usage(target),
                            **({"closest_entries": miss["closest_entries"]} if miss.get("closest_entries") else {}),
                        })
                    if act == "remove":
                        working.pop(idx)
                    elif act == "replace":
                        if not content:
                            return self._consolidation_failure({"success": False, "error": f"{pos}: content is required.", "usage": self._usage(target)})
                        working[idx] = content
                    else:
                        if not str(content).strip():
                            return self._consolidation_failure({"success": False, "error": f"{pos}: content is required.", "usage": self._usage(target)})
                        patched, err = _patch_entry(working[idx], old_text, str(content))
                        if patched is None:
                            return self._consolidation_failure({"success": False, "error": f"{pos}: {err}", "usage": self._usage(target)})
                        working[idx] = patched
                else:
                    return self._consolidation_failure({"success": False, "error": f"{pos}: unknown action.", "usage": self._usage(target)})
            if entries and not working:
                return self._consolidation_failure({
                    "success": False,
                    "error": "Refusing to empty memory store in a batch; keep at least one entry.",
                    "usage": self._usage(target),
                })
            new_total = len(ENTRY_DELIMITER.join(working))
            if new_total > limit:
                return self._consolidation_failure({
                    "success": False,
                    "error": f"Applying all {len(operations)} operations would put memory at {new_total:,}/{limit:,} chars.",
                    "usage": self._usage(target),
                })
            return working, f"Applied {len(operations)} operation(s)."

        return self._mutate(target, _apply)


def execute_memory_tool(
    store: MoMoMemoryStore,
    *,
    action: str | None = None,
    target: str = "memory",
    content: str | None = None,
    old_text: str | None = None,
    new_text: str | None = None,
    operations: list[dict[str, Any]] | None = None,
) -> str:
    """Execute a structured `memory` tool call (`add` / `patch` / `remove` / `operations` batch) against `store`."""
    if not content and new_text:
        content = new_text
    if target not in ("memory", "user"):
        return json.dumps({"success": False, "error": f"Invalid memory target '{target}'. Use 'memory' or 'user'."}, ensure_ascii=False)
    if operations is not None:
        if not isinstance(operations, list):
            return json.dumps({"success": False, "error": "operations must be a list of {action, content?, old_text?} objects."}, ensure_ascii=False)
        for idx, op in enumerate(operations, 1):
            if isinstance(op, dict) and op.get("target") not in (None, target):
                return json.dumps({"success": False, "error": f"Operation {idx} names a different target than top-level '{target}'."}, ensure_ascii=False)
        return json.dumps(store.apply_batch(target, operations), ensure_ascii=False)
    if not action:
        return json.dumps({"success": False, "error": "Missing required parameter: provide 'action' (add/patch/remove) or 'operations'."}, ensure_ascii=False)
    if action == "add":
        if not content:
            return json.dumps({"success": False, "error": "Content is required for 'add' action."}, ensure_ascii=False)
        return json.dumps(store.add(target, content), ensure_ascii=False)
    if action in ("patch", "remove"):
        if not old_text:
            return json.dumps({
                "success": False,
                "error": f"'{action}' needs old_text -- a short unique substring of the entry to {action}.",
                "current_entries": store._entries_for(target),
                "usage": store._usage(target),
            }, ensure_ascii=False)
        if action == "patch":
            if not content:
                return json.dumps({"success": False, "error": f"content is required for 'patch' action. {PATCH_DROP_HINT}"}, ensure_ascii=False)
            return json.dumps(store.patch(target, old_text, content), ensure_ascii=False)
        return json.dumps(store.remove(target, old_text), ensure_ascii=False)
    return json.dumps({"success": False, "error": f"Unknown action '{action}'. Use: add, patch, remove."}, ensure_ascii=False)


def memory_home(data: Path) -> Path:
    """Preserve the memory notebook and write receipts of existing installations."""
    current, legacy = data / "profile", data / "hermes"
    return legacy if legacy.is_dir() and not current.exists() else current


class MoMoMemory:
    """Unified engine-agnostic Memory & Markdown Notebook manager for MoMo Agent.

    Accepts `<data>` (agent root), `<data>/memories`, or its profile directory and ensures
    `<data>/memories` and the profile notebook resolve to the exact same Markdown files.
    """

    def __init__(self, root: str | Path):
        raw = Path(root)
        if raw.name == "memories":
            self.home = raw.parent
            self._memories_dir = raw
        elif raw.name in {"profile", "hermes"}:
            self.home = raw
            self._memories_dir = raw / "memories"
            self._ensure_shared_symlink(raw.parent, self._memories_dir)
        elif (raw / "profile").is_dir() or (raw / "hermes").is_dir() or (raw / "context").is_dir() or (raw / "runtime").is_dir() or (raw / "superagent").is_dir():
            # Passed top-level agent data root `<data>`
            profile = memory_home(raw)
            profile_mem = profile / "memories"
            top_mem = raw / "memories"
            if profile_mem.exists() and not top_mem.exists():
                self._ensure_shared_symlink(raw, profile_mem)
                self.home = profile
                self._memories_dir = profile_mem
            elif top_mem.is_symlink():
                self.home = profile
                self._memories_dir = profile_mem
            else:
                top_mem.mkdir(parents=True, exist_ok=True, mode=0o700)
                if not profile_mem.exists() and not profile_mem.is_symlink():
                    try:
                        profile.mkdir(parents=True, exist_ok=True, mode=0o700)
                        profile_mem.symlink_to("../memories")
                    except OSError:
                        pass
                self.home = raw
                self._memories_dir = top_mem
        else:
            self.home = raw
            self._memories_dir = raw / "memories"

    @staticmethod
    def _ensure_shared_symlink(data_root: Path, target_memories: Path) -> None:
        alias = data_root / "memories"
        try:
            if not alias.exists() and not alias.is_symlink():
                target_memories.mkdir(parents=True, exist_ok=True, mode=0o700)
                alias.symlink_to(target_memories.relative_to(data_root))
        except OSError:
            pass

    @property
    def memories_dir(self) -> Path:
        return self._memories_dir

    @contextmanager
    def store(self):
        self.memories_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        for name in ("MEMORY.md", "USER.md", "BRIEFING.md"):
            path = self.memories_dir / name
            if path.exists():
                path.read_text(encoding="utf-8")
        mem_store = MoMoMemoryStore(self.memories_dir)
        mem_store.load_from_disk()
        yield mem_store

    def _deleted_notebooks_path(self) -> Path:
        return self.memories_dir / ".deleted_notebooks.json"

    def _load_deleted_notebooks(self) -> set[str]:
        path = self._deleted_notebooks_path()
        if not path.is_file():
            return set()
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, list):
                return {str(x) for x in data if x}
        except (OSError, ValueError):
            pass
        return set()

    def _mark_deleted_notebook(self, kind: str, slug: str, rel_path: str | None = None) -> None:
        if kind in ("memory", "user", "briefing"):
            return
        deleted = self._load_deleted_notebooks()
        if kind in ("person", "topic", "project"):
            deleted.add(f"{kind}:{slug}")
        if rel_path:
            deleted.add(f"path:{rel_path}")
        _atomic_write_markdown(
            self._deleted_notebooks_path(),
            json.dumps(sorted(deleted), ensure_ascii=False, indent=2) + "\n",
        )

    def _is_deleted_notebook(self, kind: str, slug: str, rel_path: str, deleted: set[str] | None = None) -> bool:
        store = self._load_deleted_notebooks() if deleted is None else deleted
        return f"{kind}:{slug}" in store or f"path:{rel_path}" in store

    def _prune_empty_parents(self, file_path: Path) -> None:
        root = self.memories_dir.resolve()
        try:
            cur = file_path.parent.resolve()
        except OSError:
            return
        while cur != root and root in cur.parents:
            try:
                cur.rmdir()
            except OSError:
                break
            cur = cur.parent

    @staticmethod
    def _classify_rel_path(rel_posix: str) -> tuple[str, str]:
        if rel_posix.upper() == "BRIEFING.MD":
            return "briefing", "BRIEFING"
        parts = rel_posix.split("/")
        stem_rel = rel_posix[:-3] if rel_posix.lower().endswith(".md") else rel_posix
        if len(parts) >= 2:
            kind = _STANDARD_ROOT_FOLDERS.get(parts[0].lower(), "note")
            if kind != "note":
                slug = "/".join(parts[1:])
                if slug.lower().endswith(".md"):
                    slug = slug[:-3]
                return kind, slug
        return "note", stem_rel

    def _notebook_files(self) -> list[tuple[str, str, Path]]:
        root = self.memories_dir
        if not root.is_dir():
            return []
        deleted = self._load_deleted_notebooks()
        results: list[tuple[str, str, Path]] = []
        for md_file in sorted(root.rglob("*.md")):
            if not md_file.is_file():
                continue
            try:
                rel_parts = md_file.relative_to(root).parts
            except ValueError:
                continue
            if not rel_parts or any(part.startswith(".") for part in rel_parts):
                continue
            if len(rel_parts) == 1 and rel_parts[0].upper() in {"MEMORY.MD", "USER.MD"}:
                continue
            rel_posix = "/".join(rel_parts)
            if len(rel_parts) == 1 and rel_parts[0].upper() == "BRIEFING.MD":
                results.append(("briefing", "BRIEFING", md_file))
                continue
            kind, slug = self._classify_rel_path(rel_posix)
            if self._is_deleted_notebook(kind, slug, rel_posix, deleted):
                continue
            results.append((kind, slug, md_file))
        return results

    @staticmethod
    def items(store, home: Path | None = None):
        items = []
        for target, entries in (("memory", store.memory_entries), ("user", store.user_entries)):
            for text in entries:
                digest = hashlib.sha256(text.encode()).hexdigest()
                items.append({
                    "id": f"momo-{target}-{digest}",
                    "text": text,
                    "kind": target,
                    "basis": "momo",
                    "status": "current",
                    "revision": int(digest[:15], 16),
                    "evidence": [],
                })
        if home is not None:
            helper = MoMoMemory(home)
            for kind, _, path in helper._notebook_files():
                try:
                    raw = path.read_text(encoding="utf-8").strip()
                except OSError:
                    continue
                if not raw:
                    continue
                digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
                items.append({
                    "id": f"momo-{kind}-{digest}",
                    "text": raw,
                    "kind": kind,
                    "basis": "dream",
                    "status": "current",
                    "revision": int(digest[:15], 16),
                    "evidence": [],
                    "path": path.relative_to(helper.memories_dir).as_posix(),
                })
        return sorted(items, key=lambda item: item["id"])

    def list(self, after: str = "", limit: int = 100, expected_revision: int | None = None):
        if not 1 <= limit <= 200:
            raise ValueError("limit must be 1...200")
        with self.store() as store:
            items = self.items(store, self.home)
        revision = int(hashlib.sha256("\n".join(item["id"] for item in items).encode()).hexdigest()[:15], 16)
        if expected_revision is not None and revision != expected_revision:
            raise Conflict("Memory changed; refresh the current entries")
        page = [item for item in items if item["id"] > after]
        return {
            "revision": revision,
            "items": page[:limit],
            "next_cursor": page[limit - 1]["id"] if len(page) > limit else None,
        }

    def forget(self, identity: str):
        if not isinstance(identity, str) or not re.fullmatch(
            r"(?:hermes|momo)-(memory|user|briefing|project|journal|person|topic|note)-[0-9a-f]{64}", identity
        ):
            raise Conflict("This is an old memory view; refresh memory before editing")
        norm_id = "momo-" + identity.split("-", 1)[1]
        with self.store() as store:
            item = next((item for item in self.items(store, self.home) if item["id"] == norm_id), None)
            if item:
                if item["kind"] in ("memory", "user"):
                    result = store.remove(item["kind"], item["text"], matched_entry=item["text"])
                    if not result.get("success"):
                        raise Conflict(result.get("error", "Memory changed; refresh and retry"))
                else:
                    for kind, slug, path in self._notebook_files():
                        if kind != item["kind"]:
                            continue
                        try:
                            raw = path.read_text(encoding="utf-8").strip()
                        except OSError:
                            continue
                        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
                        if f"momo-{kind}-{digest}" == norm_id:
                            rel_posix = path.relative_to(self.memories_dir).as_posix()
                            path.unlink(missing_ok=True)
                            self._prune_empty_parents(path)
                            self._mark_deleted_notebook(kind, slug, rel_posix)
                            break
        return {"id": identity, "status": "forgotten"}

    @staticmethod
    def _normalize_notebook_category(category: str) -> str:
        cat = str(category or "").strip().strip("/")
        lower = cat.lower()
        return {
            "people": "person",
            "topics": "topic",
            "journals": "journal",
            "projects": "project",
            "notes": "note",
        }.get(lower, lower if lower in NOTEBOOK_KINDS else cat)

    def resolve_notebook_target(
        self,
        category: str | None = None,
        slug: str | None = None,
        *,
        path: str | None = None,
    ) -> tuple[str, str, str, Path]:
        """Resolve `(kind, slug, rel_posix, full_path)` supporting multi-level folders & custom paths."""
        raw_path = str(path or "").strip().strip("/")
        raw_cat = str(category or "").strip().strip("/")
        raw_slug = str(slug or "").strip().strip("/")

        # Treat category itself as a relative .md path if caller passed e.g. category="projects/ai/okr.md" with no slug
        if not raw_path and raw_cat.lower().endswith(".md") and not raw_slug:
            raw_path = raw_cat
            raw_cat = ""

        if raw_path:
            if "\\" in raw_path or ".." in raw_path:
                raise ValueError("Invalid notebook path")
            upper_single = raw_path.upper()
            if upper_single in {"MEMORY.MD", "USER.MD", "MEMORY", "USER"}:
                raise ValueError("Use the 'memory' / 'update_core_memory' tool to edit MEMORY.md or USER.md.")
            if upper_single in {"BRIEFING.MD", "BRIEFING"}:
                return "briefing", "BRIEFING", "BRIEFING.md", self.memories_dir / "BRIEFING.md"
            raw_parts = [p for p in raw_path.split("/") if p.strip()]
            if not raw_parts or len(raw_parts) > _MAX_NOTEBOOK_DEPTH:
                raise ValueError(f"Notebook path must have 1..{_MAX_NOTEBOOK_DEPTH} segments")
            clean_parts = [
                _sanitize_path_segment(seg, strip_md=(i == len(raw_parts) - 1))
                for i, seg in enumerate(raw_parts)
            ]
            if len(clean_parts) == 1 and clean_parts[0].upper() in {"MEMORY", "USER"}:
                raise ValueError("Use the 'memory' / 'update_core_memory' tool to edit MEMORY.md or USER.md.")
            if len(clean_parts) == 1 and clean_parts[0].upper() == "BRIEFING":
                return "briefing", "BRIEFING", "BRIEFING.md", self.memories_dir / "BRIEFING.md"
            if len(clean_parts) >= 2 and clean_parts[0].lower() in _STANDARD_ROOT_FOLDERS:
                kind = _STANDARD_ROOT_FOLDERS[clean_parts[0].lower()]
                clean_parts[0] = _CANONICAL_FOLDER_FOR_KIND[kind]
                resolved_slug = "/".join(clean_parts[1:])
            else:
                kind = "note"
                resolved_slug = "/".join(clean_parts)
            rel_posix = "/".join(clean_parts) + ".md"
            full = (self.memories_dir / rel_posix).resolve()
            root_resolved = self.memories_dir.resolve()
            if root_resolved not in full.parents:
                raise ValueError("Invalid notebook path outside memories directory")
            return kind, resolved_slug, rel_posix, self.memories_dir / rel_posix

        norm_cat = self._normalize_notebook_category(raw_cat)
        if norm_cat == "briefing" and not raw_slug:
            return "briefing", "BRIEFING", "BRIEFING.md", self.memories_dir / "BRIEFING.md"
        if norm_cat in ("memory", "user"):
            raise ValueError("Use the 'memory' / 'update_core_memory' tool to edit MEMORY.md or USER.md.")

        folder_parts: list[str] = []
        if norm_cat in _CANONICAL_FOLDER_FOR_KIND:
            folder_parts = [_CANONICAL_FOLDER_FOR_KIND[norm_cat]]
        elif norm_cat in ("note", ""):
            folder_parts = []
        else:
            if "\\" in raw_cat or ".." in raw_cat:
                raise ValueError("Invalid notebook category folder")
            raw_cat_parts = [p for p in raw_cat.split("/") if p.strip()]
            folder_parts = [_sanitize_path_segment(seg, strip_md=False) for seg in raw_cat_parts]
            if folder_parts and folder_parts[0].lower() in _STANDARD_ROOT_FOLDERS:
                mapped_kind = _STANDARD_ROOT_FOLDERS[folder_parts[0].lower()]
                folder_parts[0] = _CANONICAL_FOLDER_FOR_KIND[mapped_kind]

        clean_slug = sanitize_notebook_slug(raw_slug)
        slug_parts = clean_slug.split("/")
        # Avoid accidental prefix duplication like category='project', slug='projects/ai/okr'
        if folder_parts and len(slug_parts) > len(folder_parts) and [p.lower() for p in slug_parts[:len(folder_parts)]] == [p.lower() for p in folder_parts]:
            slug_parts = slug_parts[len(folder_parts):]

        combined = folder_parts + slug_parts
        if not combined or len(combined) > _MAX_NOTEBOOK_DEPTH:
            raise ValueError(f"Notebook path depth exceeds maximum ({_MAX_NOTEBOOK_DEPTH})")
        if len(combined) == 1 and combined[0].upper() in {"MEMORY", "USER"}:
            raise ValueError("Use the 'memory' / 'update_core_memory' tool to edit MEMORY.md or USER.md.")
        if len(combined) == 1 and combined[0].upper() == "BRIEFING":
            return "briefing", "BRIEFING", "BRIEFING.md", self.memories_dir / "BRIEFING.md"

        if len(combined) >= 2 and combined[0].lower() in _STANDARD_ROOT_FOLDERS:
            kind = _STANDARD_ROOT_FOLDERS[combined[0].lower()]
            combined[0] = _CANONICAL_FOLDER_FOR_KIND[kind]
            resolved_slug = "/".join(combined[1:])
        else:
            kind = "note"
            resolved_slug = "/".join(combined)

        rel_posix = "/".join(combined) + ".md"
        full = (self.memories_dir / rel_posix).resolve()
        root_resolved = self.memories_dir.resolve()
        if root_resolved not in full.parents:
            raise ValueError("Invalid notebook path outside memories directory")
        return kind, resolved_slug, rel_posix, self.memories_dir / rel_posix

    def resolve_notebook_path(self, category: str, slug: str | None = None, *, path: str | None = None) -> tuple[str, Path]:
        _, resolved_slug, _, full_path = self.resolve_notebook_target(category, slug, path=path)
        return resolved_slug, full_path

    def list_notebook(self, category: str | None = None, *, path_prefix: str | None = None) -> list[dict]:
        filter_cat = None
        prefix_filter = str(path_prefix or "").strip().strip("/").lower()
        if category:
            raw_c = str(category).strip().strip("/")
            norm_c = self._normalize_notebook_category(raw_c)
            if norm_c in NOTEBOOK_KINDS:
                filter_cat = norm_c
            else:
                prefix_filter = raw_c.lower()
        entries = []
        for kind, slug, file_path in self._notebook_files():
            rel_posix = file_path.relative_to(self.memories_dir).as_posix()
            if filter_cat and kind != filter_cat:
                continue
            if prefix_filter and not (rel_posix.lower() == prefix_filter or rel_posix.lower().startswith(prefix_filter + "/")):
                continue
            try:
                text = file_path.read_text(encoding="utf-8").strip()
                stat = file_path.stat()
            except OSError:
                continue
            if not text:
                continue
            first_nonempty = next((ln.strip() for ln in text.splitlines() if ln.strip()), "")
            has_h1 = bool(re.match(r"^#\s+\S", first_nonempty))
            first_line = first_nonempty.lstrip("# ").strip() if first_nonempty else Path(rel_posix).stem
            entries.append({
                "category": kind,
                "slug": slug,
                "path": rel_posix,
                "title": first_line[:120],
                "has_h1": has_h1,
                "characters": len(text),
                "updated_at": round(stat.st_mtime, 2),
            })
        return entries

    def read_notebook(self, category: str | None = None, slug: str | None = None, *, path: str | None = None) -> dict:
        kind, clean_slug, rel_posix, full_path = self.resolve_notebook_target(category, slug, path=path)
        if not full_path.is_file():
            return {"success": False, "error": f"Note not found: {rel_posix}"}
        text = full_path.read_text(encoding="utf-8").strip()
        return {
            "success": True,
            "category": kind,
            "slug": clean_slug,
            "path": rel_posix,
            "content": text,
            "characters": len(text),
        }

    def write_notebook(
        self,
        category: str | None = None,
        content: str = "",
        slug: str | None = None,
        title: str | None = None,
        mode: str = "replace",
        *,
        path: str | None = None,
    ) -> dict:
        kind, clean_slug, rel_posix, full_path = self.resolve_notebook_target(category, slug or (None if path else title), path=path)
        if self._is_deleted_notebook(kind, clean_slug, rel_posix):
            return {
                "success": False,
                "error": f"Notebook {rel_posix} was deleted by user; do not recreate it.",
            }
        body = str(content or "").strip()
        if not body:
            return {"success": False, "error": "Markdown content is required."}
        if len(body) > 32_000:
            return {"success": False, "error": "Markdown note exceeds 32,000 characters; keep notes concise and focused."}
        if (body.startswith("{") and body.endswith("}")) or (body.startswith("[") and body.endswith("]")):
            return {"success": False, "error": "Notebook notes must be pure Markdown (.md), never raw JSON."}
        if mode == "append" and full_path.is_file():
            existing = full_path.read_text(encoding="utf-8").strip()
            if existing:
                body = existing + "\n\n" + body
        if not re.match(r"^#\s+\S", body.lstrip()):
            derived_title = (title or "").strip()
            if not derived_title:
                first_h2 = next((ln.lstrip("# ").strip() for ln in body.splitlines() if ln.strip().startswith("#")), "")
                derived_title = re.sub(r"^\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}:\d{2}(?:[–—-]\d{1,2}:\d{2})?)?\s*[·•—–:：\-]?\s*", "", first_h2).strip() or Path(rel_posix).stem
            body = f"# {derived_title}\n\n{body}"
        _atomic_write_markdown(full_path, body + "\n")
        return {
            "success": True,
            "category": kind,
            "slug": clean_slug,
            "path": rel_posix,
            "characters": len(body),
            "updated_at": round(time.time(), 2),
        }

    def remove_notebook(
        self,
        category: str | None = None,
        slug: str | None = None,
        *,
        path: str | None = None,
        user_initiated: bool = False,
    ) -> dict:
        kind, clean_slug, rel_posix, full_path = self.resolve_notebook_target(category, slug, path=path)
        if not full_path.is_file():
            return {"success": False, "error": f"Note not found: {rel_posix}"}
        full_path.unlink(missing_ok=True)
        self._prune_empty_parents(full_path)
        if user_initiated:
            self._mark_deleted_notebook(kind, clean_slug, rel_posix)
        return {"success": True, "category": kind, "slug": clean_slug, "path": rel_posix, "removed": True}

    def move_notebook(
        self,
        category: str | None = None,
        slug: str | None = None,
        *,
        path: str | None = None,
        to_path: str | None = None,
        to_category: str | None = None,
        to_slug: str | None = None,
        overwrite: bool = False,
    ) -> dict:
        src_kind, src_slug, src_rel, src_full = self.resolve_notebook_target(category, slug, path=path)
        if src_kind == "briefing":
            return {"success": False, "error": "BRIEFING.md must remain at the root of memories/."}
        if not src_full.is_file():
            return {"success": False, "error": f"Source note not found: {src_rel}"}
        dst_kind, dst_slug, dst_rel, dst_full = self.resolve_notebook_target(
            to_category,
            to_slug or (Path(src_rel).stem if to_category and not to_path else None),
            path=to_path,
        )
        if dst_kind == "briefing":
            return {"success": False, "error": "Cannot move a note onto BRIEFING.md; use write with category='briefing'."}
        if self._is_deleted_notebook(dst_kind, dst_slug, dst_rel):
            return {"success": False, "error": f"Destination {dst_rel} was deleted by user; do not recreate it."}
        if src_full.resolve() == dst_full.resolve():
            return {"success": True, "from_path": src_rel, "path": dst_rel, "category": dst_kind, "slug": dst_slug, "moved": False}
        if dst_full.exists() and not overwrite:
            return {"success": False, "error": f"Destination already exists: {dst_rel}. Merge content with write+remove or set overwrite=true."}
        raw = src_full.read_text(encoding="utf-8")
        _atomic_write_markdown(dst_full, raw)
        src_full.unlink(missing_ok=True)
        self._prune_empty_parents(src_full)
        return {
            "success": True,
            "from_path": src_rel,
            "path": dst_rel,
            "category": dst_kind,
            "slug": dst_slug,
            "moved": True,
        }
