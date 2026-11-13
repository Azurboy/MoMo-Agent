"""Mac-issued one-use codes and independent, revocable browser/watch grants."""
from __future__ import annotations

import hashlib
import secrets
import sqlite3
import time
import uuid
from pathlib import Path


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class MobileAccess:
    def __init__(self, directory: Path):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.db = sqlite3.connect(directory / "pairing.sqlite", timeout=8)
        (directory / "pairing.sqlite").chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS identity (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS invites (
                role TEXT PRIMARY KEY, challenge TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS grants (
                id TEXT PRIMARY KEY, role TEXT NOT NULL, device TEXT, hash TEXT NOT NULL UNIQUE,
                created INTEGER NOT NULL, last_seen INTEGER, recording INTEGER, pending INTEGER);
        """)
        if "status_at" not in [r[1] for r in self.db.execute("PRAGMA table_info(grants)")]:
            self.db.execute("ALTER TABLE grants ADD COLUMN status_at INTEGER")
        with self.db:
            for key in ("receiver_id", "library_id"):
                self.db.execute("INSERT OR IGNORE INTO identity VALUES(?,?)", (key, str(uuid.uuid4())))
        self.identity = dict(self.db.execute("SELECT key,value FROM identity"))

    def issue(self, role: str) -> str:
        if role not in ("browser", "watch"):
            raise ValueError("未知设备类型")
        code = f"{secrets.randbelow(100_000_000):08d}"
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO invites VALUES(?,?,?,0)",
                            (role, digest(code), int(time.time()) + 600))
        return code

    def pair(self, role, code, device=None):
        if role not in ("browser", "watch") or not isinstance(code, str) or len(code) != 8 or not code.isascii() or not code.isdigit():
            raise ValueError("请输入 Mac 显示的八位配对码")
        if role == "watch":
            device = str(uuid.UUID(str(device)))
        else:
            device = None
        now = int(time.time())
        with self.db:
            self.db.execute("BEGIN IMMEDIATE")
            invitation = self.db.execute("SELECT * FROM invites WHERE role=?", (role,)).fetchone()
            if invitation is None or invitation["expires"] <= now or invitation["attempts"] >= 8:
                return None
            if not secrets.compare_digest(invitation["challenge"], digest(code)):
                self.db.execute("UPDATE invites SET attempts=attempts+1 WHERE role=?", (role,))
                return None
            self.db.execute("DELETE FROM invites WHERE role=?", (role,))
            if device:
                self.db.execute("DELETE FROM grants WHERE role='watch' AND device=?", (device,))
            token = secrets.token_urlsafe(36)
            self.db.execute("INSERT INTO grants(id,role,device,hash,created) VALUES(?,?,?,?,?)",
                            (str(uuid.uuid4()), role, device, digest(token), now))
        return token

    def grant(self, role, token):
        if not token or len(token) > 160:
            return None
        return self.db.execute("SELECT * FROM grants WHERE role=? AND hash=?", (role, digest(token))).fetchone()

    def forget(self, ident):
        with self.db:
            return self.db.execute("DELETE FROM grants WHERE id=?", (ident,)).rowcount

    def watch_seen(self, ident, recording=None, pending=None):
        with self.db:
            if recording is None:
                self.db.execute("UPDATE grants SET last_seen=? WHERE id=?", (int(time.time()), ident))
            else:
                now = int(time.time())
                self.db.execute("UPDATE grants SET last_seen=?,status_at=?,recording=?,pending=? WHERE id=?",
                                (now, now, int(recording), pending, ident))

    def watch_status(self):
        row = self.db.execute("SELECT status_at,recording,pending FROM grants WHERE role='watch' ORDER BY last_seen DESC,created DESC LIMIT 1").fetchone()
        return {"last_seen": row["status_at"] if row else None,
                "recording": bool(row["recording"]) if row and row["recording"] is not None else None,
                "pending": row["pending"] if row else None}
