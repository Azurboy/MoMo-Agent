"""Durable product inbox, visible messages, completion receipts and notification outbox.

Hermes SessionDB remains the only execution authority and memory store.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import time
import uuid
from aiohttp import web
from conversation_events import ConversationEvents

_DELIVERABLE_DOC_TYPES = {
    '.html': 'text/html',
    '.htm': 'text/html',
    '.md': 'text/markdown',
    '.markdown': 'text/markdown',
    '.csv': 'text/csv',
    '.json': 'application/json',
    '.txt': 'text/plain',
}
_DELIVERABLE_IMAGE_TYPES = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
}
_AUTO_SCAN_EXTENSIONS = ('.html', '.htm', '.md', '.markdown', '.csv', '.png', '.jpg', '.jpeg')
_IGNORED_FILENAMES = frozenset({
    'memory.md', 'user.md', 'package.json', 'pnpm-lock.yaml', 'package-lock.json',
    'tsconfig.json', 'cordis.yml', 'cordis.patch.yml', 'pnpm-workspace.yaml',
})
_IGNORED_DIRNAMES = frozenset({'.git', 'node_modules', '__pycache__', '.venv', 'venv', 'attachments'})
_ABS_PATH_PATTERN = re.compile(
    r"""(?P<path>(?:\$DSH_SUPERAGENT_MOMO_WORKSPACE|/(?:Users|private|var|tmp|Volumes))/[^\s`"'<>()\[\]{}，。；：！？）》】]+)"""
)
_REL_FILE_PATTERN = re.compile(
    r"""(?<![A-Za-z0-9_/:.-])(?P<rel>(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_\u4e00-\u9fff.-]+\.(?:html?|md|markdown|csv|json|txt|png|jpe?g))""",
    re.IGNORECASE,
)


def _strip_path_punctuation(raw: str) -> str:
    return raw.strip().rstrip(".,;:!?)>]}\"'`，。；：！？）》】")


def collect_deliverable_attachments(
    text: str | None,
    *,
    allowed_roots: list[Path] | tuple[Path, ...],
    extra_dirs: list[Path] | tuple[Path, ...] = (),
    source_key: str = "",
    max_items: int = 4,
    max_text_bytes: int = 512_000,
    max_image_bytes: int = 1_048_576,
) -> list[dict] | None:
    """Resolve sandboxed workspace deliverable files (.html, .md, etc.) into AgentAttachment payloads."""
    resolved_roots: list[Path] = []
    for root in allowed_roots:
        try:
            r = Path(root).expanduser().resolve()
        except OSError:
            continue
        if r.is_dir() and r not in resolved_roots:
            resolved_roots.append(r)
    if not resolved_roots or max_items <= 0:
        return None

    workspace_root = resolved_roots[0]
    resolved_extra_dirs: list[Path] = []
    for d in extra_dirs:
        try:
            rd = Path(d).expanduser().resolve()
        except OSError:
            continue
        if rd.is_dir() and any(rd.is_relative_to(r) for r in resolved_roots) and rd not in resolved_extra_dirs:
            resolved_extra_dirs.append(rd)

    def _is_allowed_file(candidate: Path, *, allow_aux_doc: bool) -> Path | None:
        try:
            rp = candidate.expanduser().resolve()
        except OSError:
            return None
        if not rp.is_file():
            return None
        matched_root = next((r for r in resolved_roots if rp.is_relative_to(r)), None)
        if matched_root is None:
            return None
        rel_parts = rp.relative_to(matched_root).parts
        if any(part.startswith('.') or part.lower() in _IGNORED_DIRNAMES for part in rel_parts[:-1]):
            return None
        if rp.name.startswith('.') or rp.name.lower() in _IGNORED_FILENAMES:
            return None
        ext = rp.suffix.lower()
        if ext in _DELIVERABLE_IMAGE_TYPES:
            return rp
        if ext in _DELIVERABLE_DOC_TYPES:
            if not allow_aux_doc and ext not in _AUTO_SCAN_EXTENSIONS:
                return None
            return rp
        return None

    ordered_files: list[Path] = []
    seen_paths: set[Path] = set()

    def _add(p: Path | None) -> None:
        if p is not None and p not in seen_paths:
            seen_paths.add(p)
            ordered_files.append(p)

    body = text or ""
    if body:
        for m in _ABS_PATH_PATTERN.finditer(body):
            raw_p = _strip_path_punctuation(m.group("path"))
            if raw_p.startswith("$DSH_SUPERAGENT_MOMO_WORKSPACE"):
                sub = raw_p[len("$DSH_SUPERAGENT_MOMO_WORKSPACE") :].lstrip("/")
                cand = workspace_root / sub if sub else workspace_root
            else:
                cand = Path(raw_p)
            _add(_is_allowed_file(cand, allow_aux_doc=True))

        search_bases = [*resolved_extra_dirs, *resolved_roots]
        for m in _REL_FILE_PATTERN.finditer(body):
            rel = _strip_path_punctuation(m.group("rel")).lstrip("/")
            if not rel or ".." in Path(rel).parts:
                continue
            for base in search_bases:
                found = _is_allowed_file(base / rel, allow_aux_doc=True)
                if found is not None:
                    _add(found)
                    break

    # Scan ticket-specific directories (depth <= 2) for generated .html / .md deliverables.
    extra_candidates: list[tuple[int, float, Path]] = []
    ext_priority = {'.html': 0, '.htm': 0, '.md': 1, '.markdown': 1, '.csv': 2, '.png': 3, '.jpg': 3, '.jpeg': 3}
    for ed in resolved_extra_dirs:
        try:
            entries = [ed, *[child for child in ed.iterdir() if child.is_dir() and not child.name.startswith('.') and child.name.lower() not in _IGNORED_DIRNAMES]]
        except OSError:
            continue
        for folder in entries:
            try:
                children = list(folder.iterdir())
            except OSError:
                continue
            for child in children:
                rp = _is_allowed_file(child, allow_aux_doc=False)
                if rp is None or rp in seen_paths:
                    continue
                try:
                    mtime = rp.stat().st_mtime
                except OSError:
                    continue
                extra_candidates.append((ext_priority.get(rp.suffix.lower(), 9), -mtime, rp))

    extra_candidates.sort(key=lambda item: (item[0], item[1]))
    for _, _, rp in extra_candidates:
        _add(rp)

    if not ordered_files:
        return None

    attachments: list[dict] = []
    total_text_bytes = 0
    for rp in ordered_files:
        if len(attachments) >= max_items:
            break
        try:
            st = rp.stat()
        except OSError:
            continue
        if st.st_size <= 0:
            continue
        ext = rp.suffix.lower()
        att_id = str(
            uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"momo-deliverable:{source_key}:{rp}:{st.st_mtime_ns}:{st.st_size}",
            )
        )
        if ext in _DELIVERABLE_DOC_TYPES:
            if st.st_size > max_text_bytes or total_text_bytes + st.st_size > max_text_bytes * 2:
                continue
            try:
                raw_bytes = rp.read_bytes()
            except OSError:
                continue
            decoded = raw_bytes.decode("utf-8", errors="replace")
            if not decoded.strip():
                continue
            encoded_bytes = len(decoded.encode("utf-8"))
            if encoded_bytes > max_text_bytes:
                continue
            total_text_bytes += encoded_bytes
            attachments.append(
                {
                    "id": att_id,
                    "name": rp.name,
                    "kind": "document",
                    "media_type": _DELIVERABLE_DOC_TYPES[ext],
                    "byte_count": encoded_bytes,
                    "text": decoded,
                }
            )
        elif ext in _DELIVERABLE_IMAGE_TYPES:
            if st.st_size > max_image_bytes:
                continue
            try:
                raw_bytes = rp.read_bytes()
            except OSError:
                continue
            if not raw_bytes:
                continue
            b64 = base64.b64encode(raw_bytes).decode("ascii")
            item = {
                "id": att_id,
                "name": rp.name,
                "kind": "image",
                "media_type": _DELIVERABLE_IMAGE_TYPES[ext],
                "byte_count": len(raw_bytes),
                "data": b64,
            }
            if len(raw_bytes) <= 64_000:
                item["preview"] = b64
            attachments.append(item)

    return attachments or None

class ProductStore:
    # Inputs survive restarts and are never pruned. Keep this minimum guarantee
    # stable for the lifetime of the paired instance, including across upgrades.
    MESSAGE_RETENTION_SECONDS = 86400

    def __init__(self, path, connection):
        self.notification_available = False
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS identity(id TEXT PRIMARY KEY, root TEXT NOT NULL, created REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS messages(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL,
            role TEXT NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL,
            operation_id TEXT, run_id TEXT, source_key TEXT UNIQUE);
        CREATE TABLE IF NOT EXISTS inputs(operation_id TEXT PRIMARY KEY, content TEXT NOT NULL,
            run_id TEXT UNIQUE NOT NULL, owner_scope TEXT NOT NULL, target_run_id TEXT, target_generation INTEGER, state TEXT NOT NULL DEFAULT 'pending');
        CREATE TABLE IF NOT EXISTS completions(event_key TEXT PRIMARY KEY, owner TEXT NOT NULL,
            event_json TEXT NOT NULL, source_message_id INTEGER NOT NULL, prompt TEXT NOT NULL, origin_admission_id TEXT,
            state TEXT NOT NULL DEFAULT 'pending', admission_id TEXT, reported_message_id TEXT, result_text TEXT NOT NULL DEFAULT '',
            last_error TEXT, created_at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications(message_id TEXT PRIMARY KEY, state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS legacy_sessions(root TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS legacy_consumptions(source_message_id INTEGER PRIMARY KEY, admission_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS reads(device TEXT PRIMARY KEY, through_seq INTEGER NOT NULL);
        ''')
        if 'source_session' not in {row[1] for row in self.db.execute('PRAGMA table_info(messages)')}:
            self.db.execute('ALTER TABLE messages ADD COLUMN source_session TEXT')
        with self.db:
            if not self.db.execute('SELECT 1 FROM identity').fetchone():
                self.db.execute('INSERT INTO identity VALUES(?,?,?)',
                    ('conversation-' + connection['assistant_id'], 'momo-main-' + connection['assistant_id'], time.time()))
        self.identity = dict(self.db.execute('SELECT * FROM identity').fetchone())
        if self.identity['root'] != 'momo-main-' + connection['assistant_id']:
            self.db.close(); raise ValueError('Conversation belongs to another assistant')
        self.events = ConversationEvents(self.db, self.identity['id'])
        self.db.executescript("CREATE TABLE IF NOT EXISTS works(id TEXT PRIMARY KEY,native_root TEXT UNIQUE NOT NULL,origin_run_id TEXT,title TEXT NOT NULL,created_at REAL NOT NULL,context_through_seq INTEGER NOT NULL,context_json TEXT NOT NULL,cancel_requested INTEGER NOT NULL DEFAULT 0);\nCREATE TABLE IF NOT EXISTS work_children(id TEXT PRIMARY KEY,work_id TEXT NOT NULL,origin_run_id TEXT,kind TEXT NOT NULL,native_id TEXT NOT NULL,incarnation REAL NOT NULL,generation INTEGER NOT NULL,title TEXT NOT NULL,state TEXT NOT NULL,cancel_requested INTEGER NOT NULL DEFAULT 0);\nCREATE TABLE IF NOT EXISTS work_cancels(operation_id TEXT PRIMARY KEY,target TEXT NOT NULL,generation INTEGER NOT NULL,state TEXT NOT NULL DEFAULT 'pending');\nCREATE TABLE IF NOT EXISTS computer_waits(run_id TEXT PRIMARY KEY,work_id TEXT NOT NULL,generation INTEGER NOT NULL,tool_call_id TEXT,lease_epoch INTEGER,state TEXT NOT NULL);")
        for name, declaration in [('work_id','TEXT'),('intent',"TEXT NOT NULL DEFAULT 'legacy'"),('delivery_state',"TEXT NOT NULL DEFAULT 'pending'"),('attachments_json','TEXT')]:
            if name not in {row[1] for row in self.db.execute('PRAGMA table_info(inputs)')}:
                self.db.execute(f'ALTER TABLE inputs ADD COLUMN {name} {declaration}')
        for table, name, declaration in [('works','active_context',"TEXT NOT NULL DEFAULT '[]'"),
                ('work_cancels','target_run_id','TEXT'),('completions','report_attempt','INTEGER NOT NULL DEFAULT 0'),
                ('messages','attachments_json','TEXT')]:
            if name not in {row[1] for row in self.db.execute(f'PRAGMA table_info({table})')}:
                self.db.execute(f'ALTER TABLE {table} ADD COLUMN {name} {declaration}')
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS report_retries(operation_id TEXT PRIMARY KEY,event_key TEXT NOT NULL,attempt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS completion_attempts(admission_id TEXT PRIMARY KEY,event_key TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS computer_calls(call_id TEXT PRIMARY KEY,run_id TEXT NOT NULL,work_id TEXT NOT NULL,
            generation INTEGER NOT NULL,state TEXT NOT NULL,wait_reason TEXT,blocking_work_id TEXT,lease_epoch INTEGER);
        ''')
        # No tool invocation survives a product process restart.
        self.db.execute("UPDATE computer_calls SET state='ended' WHERE state!='ended'")
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO works(id,native_root,title,created_at,context_through_seq,context_json) VALUES(?,?,?,?,?,?)',
                (self.identity['root'],self.identity['root'],'之前的对话',time.time(),0,'[]'))
            self.db.execute('UPDATE inputs SET work_id=? WHERE work_id IS NULL',(self.identity['root'],))
        Path(path).chmod(0o600)

    def accept(self, operation, content, scope, target=None, generation=None, work_id=None, active_context=None, attachments=None):
        with self.db:
            existing = self.db.execute('SELECT * FROM inputs WHERE operation_id=?', (operation,)).fetchone()
            if existing:
                if (existing['content'],existing['target_run_id'],existing['target_generation']) != (content,target,generation) or (work_id and existing['work_id'] != work_id):
                    raise web.HTTPConflict(reason='operation_conflict')
                return dict(existing)
            run = 'run_momo_' + operation.replace('-', '')
            attachments_json = json.dumps(attachments, ensure_ascii=False) if attachments else None
            msg_attachments = [{k: v for k, v in item.items() if k != 'data' or not item.get('preview')} for item in attachments] if attachments else None
            msg_attachments_json = json.dumps(msg_attachments, ensure_ascii=False) if msg_attachments else None
            if target is None:
                work_id = 'work-' + operation
                rows = self.db.execute("""SELECT m.seq,m.role,m.content FROM messages m LEFT JOIN inputs i ON i.operation_id=m.operation_id
                    WHERE m.role IN ('user','assistant') AND (i.intent IS NULL OR i.intent!='steer' OR i.delivery_state='applied')
                    ORDER BY m.seq DESC LIMIT 40""").fetchall()
                history = []; size = 0
                for row in rows:
                    if not row['content']: continue
                    size += len(row['content'].encode())
                    if size > 24576: break
                    history.append({'role':row['role'],'content':row['content']})
                title = ' '.join(content.split())[:64] or (attachments[0]['name'][:64] if attachments else '任务')
                self.db.execute('INSERT INTO works(id,native_root,origin_run_id,title,created_at,context_through_seq,context_json) VALUES(?,?,?,?,?,?,?)',
                    (work_id,'momo-work-' + operation,run,title,time.time(), rows[0]['seq'] if rows else 0,json.dumps(history[::-1],ensure_ascii=False)))
                self.db.execute('UPDATE works SET active_context=? WHERE id=?',(json.dumps(active_context or [],ensure_ascii=False),work_id))
            self.db.execute('INSERT INTO inputs(operation_id,content,run_id,owner_scope,target_run_id,target_generation,work_id,intent,attachments_json) VALUES(?,?,?,?,?,?,?,?,?)',
                            (operation,content,run,scope,target,generation,work_id,'steer' if target else 'new',attachments_json))
            self.db.execute('INSERT INTO messages(id,role,content,created_at,operation_id,run_id,attachments_json) VALUES(?,?,?,?,?,?,?)',
                            ('user-' + operation, 'user', content, time.time(), operation, run, msg_attachments_json))
            self.message_event('user-' + operation)
        return dict(self.db.execute('SELECT * FROM inputs WHERE operation_id=?', (operation,)).fetchone())

    @staticmethod
    def _format_message(row):
        item = dict(row)
        raw = item.pop('attachments_json', None)
        if raw:
            try: item['attachments'] = json.loads(raw)
            except ValueError: pass
        return item

    def message_states(self):
        # Small mutable projection, independent of the immutable message cursor. An
        # already-read bubble can become not_applied without deletion or duplication.
        return {'user-'+r['operation_id']:r['delivery_state'] for r in self.db.execute("SELECT operation_id,delivery_state FROM inputs WHERE intent='steer'")}

    def page(self, after=0, before=None, limit=100):
        comparator, cursor, order = ('<', before, 'DESC') if before is not None else ('>', after, 'ASC')
        rows = self.db.execute(f'SELECT * FROM messages WHERE seq {comparator} ? ORDER BY seq {order} LIMIT ?',
                               (cursor, limit + 1)).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        if before is not None: rows = rows[::-1]
        data = [self._format_message(row) for row in rows]
        return dict(data=data, next_cursor=(data[0 if before is not None else -1]['seq'] if data else cursor), has_more=more)

    def append_assistant(self, key, content, created, run_id=None, attachments=None):
        attachments_json = json.dumps(attachments, ensure_ascii=False) if attachments else None
        with self.db:
            found = self.db.execute('SELECT id, attachments_json FROM messages WHERE source_key=?', (key,)).fetchone()
            if found:
                if attachments_json and not found['attachments_json']:
                    self.db.execute('UPDATE messages SET attachments_json=? WHERE id=?', (attachments_json, found['id']))
                return found['id']
            identifier = 'assistant-' + hashlib.sha256(key.encode()).hexdigest()[:32]
            self.db.execute(
                'INSERT INTO messages(id,role,content,created_at,run_id,source_key,attachments_json) VALUES(?,?,?,?,?,?,?)',
                (identifier, 'assistant', content, created, run_id, key, attachments_json),
            )
            self.message_event(identifier)
        return identifier

    def append_legacy(self, key, role, content, created, run_id, session):
        # Backfill is presentation only: never replay old inputs or send new notifications.
        if self.db.execute('SELECT 1 FROM messages WHERE source_key=?', (key,)).fetchone(): return
        identifier = 'legacy-' + hashlib.sha256(key.encode()).hexdigest()[:32]
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO messages(id,role,content,created_at,run_id,source_key,source_session) VALUES(?,?,?,?,?,?,?)',
                (identifier, role, content, created, run_id, key, session))
            self.message_event(identifier)

    def project_assistant(self, admission, ordinal, content, created, run_id, attachments=None):
        # Interim callbacks and native persisted messages have independent ordinals.
        # Never let the first acknowledgement consume the final answer's identity.
        key = f'native-turn:{admission}:{ordinal}'
        attachments_json = json.dumps(attachments, ensure_ascii=False) if attachments else None
        with self.db:
            found = self.db.execute('SELECT id, attachments_json FROM messages WHERE source_key=?', (key,)).fetchone()
            if found:
                if attachments_json and not found['attachments_json']:
                    self.db.execute('UPDATE messages SET attachments_json=? WHERE id=?', (attachments_json, found['id']))
                return found['id']
            previous = self.db.execute('SELECT id,content,attachments_json FROM messages WHERE source_key=?',
                                       (f'turn:{admission}:{ordinal}',)).fetchone()
            if previous is None or previous['content'] != content:
                previous = self.db.execute("SELECT id,content,attachments_json FROM messages WHERE source_key LIKE ? AND run_id=? AND content=? ORDER BY seq LIMIT 1",
                                           (f'interim:{admission}:%', run_id, content)).fetchone()
            if previous is not None and previous['content'] == content:
                # Preserve already-rendered IDs and cursor positions when upgrading or
                # when Hermes persists an interim callback as a native assistant row.
                if attachments_json and not previous['attachments_json']:
                    self.db.execute('UPDATE messages SET source_key=?, attachments_json=? WHERE id=?', (key, attachments_json, previous['id']))
                else:
                    self.db.execute('UPDATE messages SET source_key=? WHERE id=?', (key, previous['id']))
                return previous['id']
        return self.append_assistant(key, content, created, run_id, attachments=attachments)

    def message_event(self, identifier):
        message = self.db.execute('SELECT * FROM messages WHERE id=?', (identifier,)).fetchone()
        self.events.append('message.created', {'message': self._format_message(message)})
