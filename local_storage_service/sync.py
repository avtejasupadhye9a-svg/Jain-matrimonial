"""Storage adapter contract and a verified, replayable single-object copy."""
from contextlib import closing
from dataclasses import dataclass
import sqlite3
from typing import Protocol


@dataclass(frozen=True)
class Staged:
    id: str
    mime: str
    sha256: str
    content: bytes


class TemporaryStorage(Protocol):
    def read(self, file_id: str) -> Staged: ...
    def delete_if_checksum(self, file_id: str, checksum: str) -> None: ...


class PermanentStorage(Protocol):
    def put(self, file_id: str, content: bytes, mime: str, checksum: str) -> dict: ...
    def metadata(self, file_id: str) -> dict: ...


class SyncJournal(Protocol):
    def confirmed(self, file_id: str) -> str | None: ...
    def confirm(self, file_id: str, checksum: str) -> None: ...


class SqliteSyncJournal:
    """Durable copy confirmations for an isolated local sync runner."""
    def __init__(self, database):
        self.database = database
        with closing(sqlite3.connect(database)) as db, db:
            db.execute("""CREATE TABLE IF NOT EXISTS confirmations(
                file_id TEXT PRIMARY KEY, checksum TEXT NOT NULL
            )""")

    def confirmed(self, file_id):
        with closing(sqlite3.connect(self.database)) as db:
            row = db.execute("SELECT checksum FROM confirmations WHERE file_id=?", (file_id,)).fetchone()
            return row[0] if row else None

    def confirm(self, file_id, checksum):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute("INSERT OR IGNORE INTO confirmations VALUES(?,?)", (file_id, checksum))
            row = db.execute("SELECT checksum FROM confirmations WHERE file_id=?", (file_id,)).fetchone()
            if row[0] != checksum:
                raise ValueError("Object ID already has a different confirmed checksum")

def sync_one(file_id, staging: TemporaryStorage, permanent: PermanentStorage, journal: SyncJournal):
    checksum = journal.confirmed(file_id)
    if checksum is None:
        staged = staging.read(file_id)
        if staged.id != file_id:
            raise ValueError("Staging identifier mismatch")
        checksum = staged.sha256
        permanent.put(file_id, staged.content, staged.mime, checksum)
        if permanent.metadata(file_id)["sha256"] != checksum:
            raise ValueError("Permanent verification failed")
        journal.confirm(file_id, checksum)
    elif permanent.metadata(file_id)["sha256"] != checksum:
        raise ValueError("Permanent copy cannot be confirmed")
    staging.delete_if_checksum(file_id, checksum)


