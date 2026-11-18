"""Loopback-only file origin. Run with python -m local_storage_service.service."""
import hashlib
import hmac
import json
import os
import re
import tempfile
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024
SIGNATURES = {"image/jpeg": b"\xff\xd8\xff", "image/png": b"\x89PNG\r\n\x1a\n", "application/pdf": b"%PDF-"}
SHA256 = re.compile(r"[0-9a-f]{64}")
FILE_ROUTE = re.compile(r"/objects/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})")


class StorageError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class Storage:
    def __init__(self, root, scan):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.scan = scan

    def path(self, file_id):
        if str(uuid.UUID(file_id)) != file_id:
            raise StorageError(400, "Invalid object ID")
        return self.root / file_id

    def metadata(self, file_id):
        path = self.path(file_id)
        if not path.is_file():
            raise StorageError(404, "Object unavailable")
        with path.open("rb") as handle:
            checksum = hashlib.file_digest(handle, "sha256").hexdigest()
        return {"id": file_id, "sha256": checksum, "bytes": path.stat().st_size}

    def put(self, file_id, content, mime, checksum):
        signature = SIGNATURES.get(mime)
        if signature is None or not content.startswith(signature):
            raise StorageError(415, "Unsupported file content")
        if len(content) > MAX_BYTES or not SHA256.fullmatch(checksum):
            raise StorageError(400, "Invalid object metadata")
        if not hmac.compare_digest(hashlib.sha256(content).hexdigest(), checksum):
            raise StorageError(422, "Checksum mismatch")
        if not self.scan(content, mime):
            raise StorageError(422, "Object failed validation")
        path = self.path(file_id)
        with tempfile.NamedTemporaryFile(dir=self.root, delete=False) as temporary:
            temp = Path(temporary.name)
            try:
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
                temporary.close()
                try:
                    if os.name == 'nt':
                        os.rename(temp, path)
                    else:
                        os.link(temp, path)
                except FileExistsError:
                    pass
            finally:
                temp.unlink(missing_ok=True)
        result = self.metadata(file_id)
        if not hmac.compare_digest(result["sha256"], checksum):
            raise StorageError(409, "Object ID already has different content")
        return result


def server(storage, token, port=8765):
    if len(token) < 32:
        raise ValueError("JAIN_STORAGE_TOKEN must be at least 32 characters")

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(12)
            super().setup()

        def log_message(self, *_):
            return

        def respond(self, status, data):
            payload = json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def handle_object(self, upload):
            try:
                supplied = self.headers.get("Authorization", "").encode()
                if not hmac.compare_digest(supplied, ("Bearer " + token).encode()):
                    raise StorageError(401, "Authentication required")
                if self.path == "/health" and not upload:
                    self.respond(200, {"status": "ok"})
                    return
                route = FILE_ROUTE.fullmatch(self.path)
                if not route:
                    raise StorageError(404, "Route unavailable")
                file_id = route[1]
                if upload:
                    length = self.headers.get("Content-Length", "")
                    if self.headers.get("Transfer-Encoding") or not length.isascii() or not length.isdigit():
                        raise StorageError(411, "Content length required")
                    size = int(length)
                    if not 1 <= size <= MAX_BYTES:
                        raise StorageError(413, "Invalid file size")
                    content = self.rfile.read(size)
                    if len(content) != size:
                        raise StorageError(400, "Incomplete file")
                    result = storage.put(file_id, content, self.headers.get_content_type(), self.headers.get("X-Content-SHA256", ""))
                else:
                    result = storage.metadata(file_id)
                self.respond(200, result)
            except StorageError as error:
                self.respond(error.status, {"error": str(error)})
            except (OSError, ValueError):
                self.respond(503, {"error": "Storage operation unavailable"})

        def do_GET(self):
            self.handle_object(False)

        def do_PUT(self):
            self.handle_object(True)

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


def run():
    if os.environ.get("JAIN_STORAGE_LOCAL_TEST") != "true":
        raise SystemExit("Storage origin requires a configured scanner. Local synthetic testing requires JAIN_STORAGE_LOCAL_TEST=true.")
    root = os.environ.get("JAIN_STORAGE_ROOT", "./local-data")
    token = os.environ.get("JAIN_STORAGE_TOKEN", "")
    with server(Storage(root, lambda _content, _mime: True), token) as service:
        service.serve_forever()


if __name__ == "__main__":
    run()


