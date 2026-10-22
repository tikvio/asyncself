"""Durable at-least-once notification inbox backed by SQLite."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import sqlite3
import time
from typing import Iterable


@dataclass(frozen=True)
class Job:
    id: int
    domain: str
    resource: str
    hint: dict
    generation: int
    attempts: int
    lease_owner: str


class Inbox:
    def __init__(self, path: str | Path):
        self.path = Path(path)

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS deliveries (
                  id INTEGER PRIMARY KEY,
                  provider TEXT NOT NULL,
                  delivery_key TEXT NOT NULL,
                  event_type TEXT NOT NULL,
                  resource TEXT NOT NULL,
                  body_hash TEXT NOT NULL,
                  received_at REAL NOT NULL,
                  UNIQUE(provider, delivery_key)
                );
                CREATE TABLE IF NOT EXISTS jobs (
                  id INTEGER PRIMARY KEY,
                  domain TEXT NOT NULL,
                  resource TEXT NOT NULL,
                  hint_json TEXT NOT NULL,
                  requested_generation INTEGER NOT NULL DEFAULT 0,
                  completed_generation INTEGER NOT NULL DEFAULT 0,
                  status TEXT NOT NULL,
                  first_requested_at REAL NOT NULL,
                  available_at REAL NOT NULL,
                  lease_owner TEXT,
                  lease_until REAL,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  last_reason TEXT,
                  UNIQUE(domain, resource)
                );
                CREATE TABLE IF NOT EXISTS mr_bindings (
                  mr_iid INTEGER NOT NULL,
                  issue_id TEXT NOT NULL,
                  verified_at REAL NOT NULL,
                  PRIMARY KEY(mr_iid, issue_id)
                );
                CREATE INDEX IF NOT EXISTS jobs_ready_idx
                  ON jobs(domain, status, available_at, lease_until);
                """
            )

    def enqueue(
        self,
        provider: str,
        delivery_key: str,
        event_type: str,
        resource: str,
        raw_body: bytes,
        jobs: Iterable[tuple[str, str, dict]],
        *,
        now: float | None = None,
        debounce_seconds: float = 2.0,
        max_debounce_seconds: float = 10.0,
    ) -> bool:
        current = time.time() if now is None else now
        digest = hashlib.sha256(raw_body).hexdigest()
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            existing = db.execute(
                "SELECT body_hash, resource FROM deliveries WHERE provider=? AND delivery_key=?",
                (provider, delivery_key),
            ).fetchone()
            if existing:
                if existing["body_hash"] != digest or existing["resource"] != resource:
                    raise RuntimeError("delivery key reused with different payload")
                db.commit()
                return False
            db.execute(
                "INSERT INTO deliveries(provider, delivery_key, event_type, resource, body_hash, received_at) "
                "VALUES(?, ?, ?, ?, ?, ?)",
                (provider, delivery_key, event_type, resource, digest, current),
            )
            for domain, job_resource, hint in jobs:
                row = db.execute(
                    "SELECT first_requested_at, requested_generation, completed_generation "
                    "FROM jobs WHERE domain=? AND resource=?",
                    (domain, job_resource),
                ).fetchone()
                first = current
                if row is not None and int(row["completed_generation"]) < int(row["requested_generation"]):
                    first = float(row["first_requested_at"])
                available = min(current + debounce_seconds, first + max_debounce_seconds)
                db.execute(
                    """
                    INSERT INTO jobs(
                      domain, resource, hint_json, requested_generation, completed_generation,
                      status, first_requested_at, available_at, attempts
                    ) VALUES(?, ?, ?, 1, 0, 'pending', ?, ?, 0)
                    ON CONFLICT(domain, resource) DO UPDATE SET
                      hint_json=excluded.hint_json,
                      requested_generation=jobs.requested_generation + 1,
                      status=CASE WHEN jobs.status='processing' THEN jobs.status ELSE 'pending' END,
                      first_requested_at=CASE
                        WHEN jobs.completed_generation >= jobs.requested_generation THEN excluded.first_requested_at
                        ELSE jobs.first_requested_at END,
                      available_at=CASE WHEN jobs.status='processing' THEN jobs.available_at ELSE excluded.available_at END,
                      last_reason=NULL
                    """,
                    (domain, job_resource, json.dumps(hint, sort_keys=True), first, available),
                )
            db.commit()
        return True

    def claim(
        self,
        domain: str,
        owner: str,
        *,
        now: float | None = None,
        lease_seconds: float = 120.0,
    ) -> Job | None:
        current = time.time() if now is None else now
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                """
                SELECT * FROM jobs
                WHERE domain=?
                  AND (
                    (status IN ('pending', 'retry') AND available_at <= ?)
                    OR (status='processing' AND lease_until <= ?)
                  )
                ORDER BY available_at, id
                LIMIT 1
                """,
                (domain, current, current),
            ).fetchone()
            if row is None:
                db.commit()
                return None
            updated = db.execute(
                "UPDATE jobs SET status='processing', lease_owner=?, lease_until=? "
                "WHERE id=? AND (status!='processing' OR lease_until<=?)",
                (owner, current + lease_seconds, row["id"], current),
            ).rowcount
            if updated != 1:
                db.rollback()
                return None
            db.commit()
            return Job(
                id=int(row["id"]),
                domain=str(row["domain"]),
                resource=str(row["resource"]),
                hint=json.loads(row["hint_json"]),
                generation=int(row["requested_generation"]),
                attempts=int(row["attempts"]),
                lease_owner=owner,
            )

    def complete(self, job: Job, *, now: float | None = None) -> bool:
        current = time.time() if now is None else now
        with self._connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT requested_generation, lease_owner, status FROM jobs WHERE id=?",
                (job.id,),
            ).fetchone()
            if row is None or row["status"] != "processing" or row["lease_owner"] != job.lease_owner:
                db.rollback()
                return False
            pending = int(row["requested_generation"]) > job.generation
            db.execute(
                """
                UPDATE jobs SET completed_generation=?, status=?, available_at=?,
                  lease_owner=NULL, lease_until=NULL, attempts=0, last_reason=NULL,
                  first_requested_at=?
                WHERE id=? AND lease_owner=?
                """,
                (
                    job.generation,
                    "pending" if pending else "complete",
                    current,
                    current,
                    job.id,
                    job.lease_owner,
                ),
            )
            db.commit()
            return True

    def fail(
        self,
        job: Job,
        reason: str,
        *,
        now: float | None = None,
        delay_seconds: float = 5.0,
        max_attempts: int = 10,
    ) -> bool:
        current = time.time() if now is None else now
        attempts = job.attempts + 1
        status = "parked" if attempts >= max_attempts else "retry"
        with self._connect() as db:
            updated = db.execute(
                """
                UPDATE jobs SET status=?, available_at=?, lease_owner=NULL, lease_until=NULL,
                  attempts=?, last_reason=?
                WHERE id=? AND status='processing' AND lease_owner=?
                """,
                (status, current + delay_seconds, attempts, reason[:200], job.id, job.lease_owner),
            ).rowcount
            return updated == 1

    def replay(self, job_id: int, *, now: float | None = None) -> bool:
        current = time.time() if now is None else now
        with self._connect() as db:
            updated = db.execute(
                """
                UPDATE jobs SET status='pending', available_at=?, attempts=0,
                  lease_owner=NULL, lease_until=NULL, last_reason='manual_replay',
                  requested_generation=requested_generation + 1,
                  first_requested_at=?
                WHERE id=?
                """,
                (current, current, job_id),
            ).rowcount
            return updated == 1

    def bind_mr(self, mr_iid: int, issue_id: str, *, now: float | None = None) -> None:
        current = time.time() if now is None else now
        with self._connect() as db:
            db.execute(
                "INSERT INTO mr_bindings(mr_iid, issue_id, verified_at) VALUES(?, ?, ?) "
                "ON CONFLICT(mr_iid, issue_id) DO UPDATE SET verified_at=excluded.verified_at",
                (mr_iid, issue_id, current),
            )

    def issues_for_mr(self, mr_iid: int) -> list[str]:
        with self._connect() as db:
            return [str(row["issue_id"]) for row in db.execute(
                "SELECT issue_id FROM mr_bindings WHERE mr_iid=? ORDER BY issue_id", (mr_iid,)
            )]

    def status(self) -> dict[str, int | float | None]:
        with self._connect() as db:
            counts = {str(row["status"]): int(row["count"]) for row in db.execute(
                "SELECT status, COUNT(*) AS count FROM jobs GROUP BY status"
            )}
            oldest = db.execute(
                "SELECT MIN(first_requested_at) AS oldest FROM jobs WHERE status!='complete'"
            ).fetchone()["oldest"]
        return {"pending": counts.get("pending", 0), "retry": counts.get("retry", 0),
                "processing": counts.get("processing", 0), "parked": counts.get("parked", 0),
                "complete": counts.get("complete", 0), "oldest_unfinished_at": oldest}

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=0.75)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA busy_timeout=750")
        return db
