"""
Ghar family leaderboard — invite-code groups, no accounts.

Three endpoints:
  POST /leaderboard/group          -> {"code": "TIGER-42"}
  POST /leaderboard/score          -> submit/update a player's stats
  DELETE /leaderboard/{code}/score -> delete one player's row (nickname query param)
  GET  /leaderboard/{code}         -> ranked player list for the group

Design notes for Som:
- The group code IS the auth. Codes are random word+number pairs, so they
  can't be guessed by scanning. No logins, no emails, nicknames only —
  that's what keeps it COPPA-clean for under-13s.
- One SQLite table. The app POSTs its local stats (XP, quiz streak best,
  quiz correct total, missions done) after playing; the app sorts into the
  four boards client-side, so the server just stores and returns raw stats.
- Fly.io note: the DB file lives on disk. Fly's filesystem is ephemeral —
  attach a volume (fly volumes create) and set the DB path to it, or scores
  reset on every deploy. Fine to skip for the first test, required after.
"""
import os
import random
import sqlite3
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/leaderboard", tags=["leaderboard"])

# Overridable via env for Fly volumes, e.g. DB_PATH=/data/leaderboard.db
DB_PATH = Path(os.environ.get("DB_PATH", Path(__file__).parent / "data" / "leaderboard.db"))

_CODE_WORDS = [
    "TIGER", "PANDA", "YETI", "EAGLE", "COBRA", "MONKEY", "RHINO", "LEOPARD",
    "FALCON", "BEAR", "WOLF", "OTTER", "PARROT", "TURTLE", "FOX", "DEER",
]


def _db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(
        """CREATE TABLE IF NOT EXISTS groups (
               code TEXT PRIMARY KEY,
               created_at REAL NOT NULL)"""
    )
    # Migration: group display name (added 2026-10-19).
    cols = [r["name"] for r in conn.execute("PRAGMA table_info(groups)").fetchall()]
    if "name" not in cols:
        conn.execute("ALTER TABLE groups ADD COLUMN name TEXT")
    conn.execute(
        """CREATE TABLE IF NOT EXISTS scores (
               group_code TEXT NOT NULL,
               nickname TEXT NOT NULL,
               xp INTEGER NOT NULL DEFAULT 0,
               quiz_streak_best INTEGER NOT NULL DEFAULT 0,
               quiz_correct_total INTEGER NOT NULL DEFAULT 0,
               missions_done INTEGER NOT NULL DEFAULT 0,
               updated_at REAL NOT NULL,
               PRIMARY KEY (group_code, nickname),
               FOREIGN KEY (group_code) REFERENCES groups(code))"""
    )
    conn.commit()
    return conn


def _sanitize_name(name: str) -> str:
    """Turn a user-typed group name into a code-safe prefix: uppercase
    alphanumeric, max 12 chars. Returns '' if nothing usable remains."""
    clean = "".join(c for c in name.upper() if c.isalnum())
    return clean[:12]


def _new_code(conn: sqlite3.Connection, name: str = "") -> str:
    prefix = _sanitize_name(name) if name else ""
    for _ in range(20):
        base = prefix if prefix else random.choice(_CODE_WORDS)
        code = f"{base}-{random.randint(10, 99)}"
        exists = conn.execute("SELECT 1 FROM groups WHERE code = ?", (code,)).fetchone()
        if not exists:
            return code
    raise HTTPException(status_code=500, detail="Could not generate a unique group code")


class ScoreIn(BaseModel):
    group_code: str = Field(..., min_length=3, max_length=16)
    nickname: str = Field(..., min_length=1, max_length=20)
    xp: int = Field(0, ge=0)
    quiz_streak_best: int = Field(0, ge=0)
    quiz_correct_total: int = Field(0, ge=0)
    missions_done: int = Field(0, ge=0)


def _cleanup_stale_groups(conn: sqlite3.Connection, days: int = 30):
    """Delete groups (and their scores) with no activity in `days`.
    Activity = latest score submission, or group creation if no scores yet.
    Runs lazily on write endpoints — no scheduler needed."""
    cutoff = time.time() - days * 86400
    rows = conn.execute(
        """SELECT g.code FROM groups g
           LEFT JOIN scores s ON s.group_code = g.code
           GROUP BY g.code
           HAVING MAX(COALESCE(s.updated_at, g.created_at)) < ?""",
        (cutoff,),
    ).fetchall()
    stale = [r["code"] for r in rows]
    if stale:
        placeholders = ",".join("?" for _ in stale)
        conn.execute(f"DELETE FROM scores WHERE group_code IN ({placeholders})", stale)
        conn.execute(f"DELETE FROM groups WHERE code IN ({placeholders})", stale)


class GroupIn(BaseModel):
    name: str = Field("", max_length=30)


@router.post("/group")
def create_group(g: GroupIn):
    """Create a leaderboard group. Optional name becomes the code prefix:
    \"Pyakurel\" -> \"PYAKUREL-42\". Returns {"code": ..., "name": ...}."""
    conn = _db()
    try:
        code = _new_code(conn, g.name)
        display = g.name.strip()[:30] if g.name.strip() else None
        conn.execute(
            "INSERT INTO groups (code, created_at, name) VALUES (?, ?, ?)",
            (code, time.time(), display),
        )
        conn.commit()
        _cleanup_stale_groups(conn)
        conn.commit()
        return {"code": code, "name": display}
    finally:
        conn.close()


@router.post("/score")
def submit_score(s: ScoreIn):
    """Upsert a player's stats. Nickname is unique per group (first come)."""
    nickname = s.nickname.strip()
    if not nickname:
        raise HTTPException(status_code=422, detail="Nickname can't be blank")
    conn = _db()
    try:
        group = conn.execute("SELECT 1 FROM groups WHERE code = ?", (s.group_code,)).fetchone()
        if not group:
            raise HTTPException(status_code=404, detail="Group code not found")
        conn.execute(
            """INSERT INTO scores
                 (group_code, nickname, xp, quiz_streak_best, quiz_correct_total, missions_done, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(group_code, nickname) DO UPDATE SET
                 xp = MAX(scores.xp, excluded.xp),
                 quiz_streak_best = MAX(scores.quiz_streak_best, excluded.quiz_streak_best),
                 quiz_correct_total = MAX(scores.quiz_correct_total, excluded.quiz_correct_total),
                 missions_done = MAX(scores.missions_done, excluded.missions_done),
                 updated_at = excluded.updated_at""",
            (s.group_code, nickname, s.xp, s.quiz_streak_best,
             s.quiz_correct_total, s.missions_done, time.time()),
        )
        conn.commit()
        _cleanup_stale_groups(conn)
        conn.commit()
        return {"ok": True}
    finally:
        conn.close()


@router.delete("/{code}/score")
def delete_score(code: str, nickname: str):
    """Delete one player's row — the app's "delete my scores" path."""
    conn = _db()
    try:
        cur = conn.execute(
            "DELETE FROM scores WHERE group_code = ? AND nickname = ?",
            (code.upper(), nickname.strip()),
        )
        conn.commit()
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Score not found")
        return {"ok": True}
    finally:
        conn.close()


@router.get("/{code}")
def get_rankings(code: str):
    """Raw stats for every player in the group, XP-desc. The app sorts
    into the XP / Streak / Quiz / Missions boards client-side."""
    conn = _db()
    try:
        group = conn.execute("SELECT name FROM groups WHERE code = ?", (code,)).fetchone()
        if not group:
            raise HTTPException(status_code=404, detail="Group code not found")
        rows = conn.execute(
            """SELECT nickname, xp, quiz_streak_best, quiz_correct_total, missions_done, updated_at
               FROM scores WHERE group_code = ? ORDER BY xp DESC""",
            (code,),
        ).fetchall()
        return {
            "code": code,
            "name": group["name"],
            "players": [
                {
                    "nickname": r["nickname"],
                    "xp": r["xp"],
                    "quiz_streak_best": r["quiz_streak_best"],
                    "quiz_correct_total": r["quiz_correct_total"],
                    "missions_done": r["missions_done"],
                }
                for r in rows
            ],
        }
    finally:
        conn.close()
