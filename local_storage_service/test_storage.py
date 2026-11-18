import hashlib
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from unittest.mock import Mock

from local_storage_service.service import Storage, StorageError, server
from local_storage_service.sync import SqliteSyncJournal, Staged, sync_one

TOKEN = "synthetic-test-token-with-32-characters"
PNG = b"\x89PNG\r\n\x1a\nsynthetic"
CHECKSUM = hashlib.sha256(PNG).hexdigest()


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.id = str(uuid.uuid4())
        self.store = Storage(self.temp.name, lambda *_: True)

    def test_atomic_dedup_and_mismatched_retry(self):
        self.assertEqual(self.store.put(self.id, PNG, "image/png", CHECKSUM)["sha256"], CHECKSUM)
        self.assertEqual(self.store.put(self.id, PNG, "image/png", CHECKSUM)["bytes"], len(PNG))
        changed = PNG + b"changed"
        with self.assertRaises(StorageError) as caught:
            self.store.put(self.id, changed, "image/png", hashlib.sha256(changed).hexdigest())
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [Path(self.temp.name) / self.id])

    def test_rejects_invalid_mime_checksum_and_scan(self):
        for content, mime, checksum in [(b"wrong", "image/png", CHECKSUM), (PNG, "image/png", "0" * 64)]:
            with self.assertRaises(StorageError):
                self.store.put(self.id, content, mime, checksum)
        self.store.scan = lambda *_: False
        with self.assertRaises(StorageError):
            self.store.put(self.id, PNG, "image/png", CHECKSUM)
        self.assertEqual(list(Path(self.temp.name).iterdir()), [])

    def test_http_auth_and_opaque_routes(self):
        with server(self.store, TOKEN, 0) as service:
            thread = threading.Thread(target=service.serve_forever)
            thread.start()
            try:
                url = f"http://127.0.0.1:{service.server_port}"
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(url + "/health", timeout=4)
                self.assertEqual(caught.exception.code, 401)
                headers = {"Authorization": "Bearer " + TOKEN, "Content-Type": "image/png", "X-Content-SHA256": CHECKSUM}
                request = urllib.request.Request(url + "/objects/" + self.id, PNG, headers=headers, method="PUT")
                with urllib.request.urlopen(request, timeout=4) as response:
                    self.assertEqual(json.load(response)["sha256"], CHECKSUM)
                request = urllib.request.Request(url + "/objects/%2e%2e", headers=headers)
                with self.assertRaises(urllib.error.HTTPError) as traversal:
                    urllib.request.urlopen(request, timeout=4)
                self.assertEqual(traversal.exception.code, 404)
            finally:
                service.shutdown()
                thread.join()

    def test_sync_never_deletes_after_failure_and_replays_confirmation(self):
        staging = Mock()
        staging.read.return_value = Staged(self.id, "image/png", CHECKSUM, PNG)
        journal = Mock()
        journal.confirmed.return_value = None
        permanent = Mock()
        permanent.metadata.return_value = {"sha256": "bad"}
        with self.assertRaises(ValueError):
            sync_one(self.id, staging, permanent, journal)
        staging.delete_if_checksum.assert_not_called()
        permanent.metadata.return_value = {"sha256": CHECKSUM}
        sync_one(self.id, staging, permanent, journal)
        journal.confirm.assert_called_once_with(self.id, CHECKSUM)
        staging.delete_if_checksum.assert_called_once_with(self.id, CHECKSUM)
        journal.confirmed.return_value = CHECKSUM
        permanent.put.reset_mock()
        sync_one(self.id, staging, permanent, journal)
        permanent.put.assert_not_called()


    def test_journal_reopens_with_immutable_confirmations(self):
        database = Path(self.temp.name) / "local-sync.sqlite"
        first = SqliteSyncJournal(database)
        self.assertIsNone(first.confirmed(self.id))
        first.confirm(self.id, CHECKSUM)
        second = SqliteSyncJournal(database)
        self.assertEqual(second.confirmed(self.id), CHECKSUM)
        second.confirm(self.id, CHECKSUM)
        with self.assertRaises(ValueError):
            second.confirm(self.id, "0" * 64)

if __name__ == "__main__":
    unittest.main()


