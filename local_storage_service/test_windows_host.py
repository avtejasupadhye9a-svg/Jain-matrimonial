import json
import os
import secrets
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from unittest.mock import Mock, patch

if os.name == "nt":
    import win32crypt
    from local_storage_service import windows_host as host
    from local_storage_service.service import server


@unittest.skipUnless(os.name == "nt", "Windows service")
class HostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.origin = str(uuid.uuid4())
        self.token = secrets.token_hex(32)
        (self.root / "origin.dpapi").write_bytes(win32crypt.CryptProtectData(self.token.encode(), None, None, None, None, 5))
        (self.root / "designation.json").write_text(json.dumps({"machine": host.machine(), "origin": self.origin}))

    def test_rejects_copied_or_damaged_enrollment(self):
        self.assertEqual(host.credentials(self.root), (self.token, self.origin))
        with patch.object(host, "machine", return_value="other-pc"), self.assertRaises(ValueError):
            host.credentials(self.root)
        (self.root / "origin.dpapi").write_bytes(b"invalid")
        with self.assertRaises(Exception):
            host.credentials(self.root)

    def test_service_start_designation_stop_and_sanitized_log(self):
        service = object.__new__(host.OriginService)
        service.stopping = threading.Event()
        ready = threading.Event()
        service.ReportServiceStatus = Mock(side_effect=lambda status, **kw: ready.set() if status == host.win32service.SERVICE_RUNNING else None)
        port = []
        def test_server(storage, token, *, origin_id):
            httpd = server(storage, token, 0, origin_id=origin_id)
            port.append(httpd.server_port)
            return httpd
        with patch.object(host, "STATE", self.root), patch.object(host, "DATA", self.root), patch.object(host, "server", test_server), patch.object(host, "scanner"), patch.object(host, "defender_scanner", return_value=lambda *_: True):
            thread = threading.Thread(target=service.SvcRun)
            thread.start()
            try:
                self.assertTrue(ready.wait(5))
                url = "http://127.0.0.1:%d/health" % port[0]
                headers = {"Authorization": "Bearer " + self.token, "X-Jain-Origin": str(uuid.uuid4())}
                with self.assertRaises(urllib.error.HTTPError) as wrong:
                    urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=4)
                self.assertEqual(wrong.exception.code, 403)
                headers["X-Jain-Origin"] = self.origin
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=4) as response:
                    self.assertEqual(response.headers["X-Jain-Origin"], self.origin)
            finally:
                service.SvcStop()
                thread.join(5)
                self.assertFalse(thread.is_alive())
        log = (self.root / "storage.log").read_text()
        self.assertIn("Service stopped", log)
        self.assertNotIn(self.token, log)

