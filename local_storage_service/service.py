"""Loopback-only file origin. Run with python -m local_storage_service.service."""
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
import uuid
import threading
import socket
import sqlite3
import time
import shutil
from contextlib import closing
import ctypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024
SIGNATURES = {"image/jpeg": b"\xff\xd8\xff", "image/png": b"\x89PNG\r\n\x1a\n", "application/pdf": b"%PDF-"}
SHA256 = re.compile(r"[0-9a-f]{64}")
FILE_ROUTE = re.compile(r"/objects/([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})(/content)?")


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

    def read(self, file_id):
        try:
            with self.path(file_id).open("rb") as handle:
                content = handle.read(MAX_BYTES + 1)
        except FileNotFoundError as error:
            raise StorageError(404, "Object unavailable") from error
        if not 1 <= len(content) <= MAX_BYTES:
            raise StorageError(503, "Invalid stored content")
        return content

    def put(self, file_id, content, mime, checksum):
        signature = SIGNATURES.get(mime)
        if signature is None or not content.startswith(signature):
            raise StorageError(415, "Unsupported file content")
        if len(content) > MAX_BYTES or not SHA256.fullmatch(checksum):
            raise StorageError(400, "Invalid object metadata")
        if not hmac.compare_digest(hashlib.sha256(content).hexdigest(), checksum):
            raise StorageError(422, "Checksum mismatch")
        path = self.path(file_id)
        if path.is_file():
            result = self.metadata(file_id)
            if hmac.compare_digest(result["sha256"], checksum):
                return result
            raise StorageError(409, "Object ID already has different content")
        if not self.scan(content, mime):
            raise StorageError(422, "Object failed validation")
        with tempfile.NamedTemporaryFile(dir=self.root, delete=False) as temporary:
            temp = Path(temporary.name)
            try:
                temporary.write(content)
                temporary.flush()
                os.fsync(temporary.fileno())
                temporary.close()
                try:
                    if os.name == 'nt':
                        # Write-through rename, without replacing an existing immutable object.
                        if not ctypes.windll.kernel32.MoveFileExW(str(temp), str(path), 8):
                            raise ctypes.WinError()
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


class OriginServer(ThreadingHTTPServer):
    daemon_threads = False
    allow_reuse_address = False

    def server_bind(self):
        if os.name == "nt":
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        def expire():
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        # A slowly trickling client must not hold a slot or an SCM stop indefinitely.
        deadline = threading.Timer(25, expire)
        deadline.start()
        try:
            super().process_request_thread(request, client_address)
        finally:
            deadline.cancel()
            self.slots.release()

    def handle_error(self, request, client_address):
        # Never include request contents in traceback or event logs.
        return


def server(storage, token, port=8765, *, origin_id=None, nonces=None, photos=None):
    if nonces:
        with closing(sqlite3.connect(nonces)) as db, db:
            db.execute("CREATE TABLE IF NOT EXISTS seen(nonce TEXT PRIMARY KEY, expires INTEGER NOT NULL)")
    if len(token) < 32:
        raise ValueError("JAIN_STORAGE_TOKEN must be at least 32 characters")

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(12)
            super().setup()

        def log_message(self, *_):
            return

        def respond(self, status, data, binary=False):
            logger = getattr(self.server, "audit_log", None)
            if logger:
                logger.info("Origin response %d", status)
            payload = data if binary else json.dumps(data).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/octet-stream" if binary else "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(payload)))
            if nonces and status == 200:
                message = "|".join([self.headers["X-Origin-Nonce"],str(status),hashlib.sha256(payload).hexdigest()])
                self.send_header("X-Origin-Proof",hmac.new(token.encode(),message.encode(),hashlib.sha256).hexdigest())
            if origin_id:
                self.send_header("X-Jain-Origin", origin_id)
            self.end_headers()
            self.wfile.write(payload)

        def handle_object(self, upload):
            try:
                supplied = self.headers.get("Authorization", "").encode()
                if nonces:
                    stamp=self.headers.get("X-Origin-Time","")
                    nonce=self.headers.get("X-Origin-Nonce","")
                    now=int(time.time())
                    if not re.fullmatch(r"[0-9]{10}",stamp) or abs(now-int(stamp))>60 or not re.fullmatch("[a-f0-9-]{36}",nonce):
                        raise StorageError(401,"Expired origin request")
                    text="|".join([origin_id,stamp,nonce,self.command,self.path,self.headers.get("X-Content-SHA256","")])
                    mac=hmac.new(token.encode(),text.encode(),hashlib.sha256).hexdigest()
                    if not hmac.compare_digest(self.headers.get("X-Origin-Mac","").encode(),mac.encode()):
                        raise StorageError(401,"Origin authentication required")
                    with closing(sqlite3.connect(nonces)) as db,db:
                        db.execute("DELETE FROM seen WHERE expires<?",(now,))
                        if not db.execute("INSERT OR IGNORE INTO seen VALUES(?,?)",(nonce,now+125)).rowcount:
                            raise StorageError(401,"Expired origin request")
                elif not hmac.compare_digest(supplied, ("Bearer " + token).encode()):
                    raise StorageError(401, "Authentication required")
                if origin_id and self.headers.get("X-Jain-Origin") != origin_id:
                    raise StorageError(403, "Origin designation mismatch")
                if self.path == "/health" and not upload:
                    self.respond(200, {"status":"ok","freeBytes":shutil.disk_usage(storage.root).free})
                    return
                photo = bool(photos and self.path.startswith("/photos/"))
                objects = photos if photo else storage
                route = FILE_ROUTE.fullmatch(self.path.replace("/photos/","/objects/",1) if photo else self.path)
                if not route or (upload and route[2]):
                    raise StorageError(404, "Route unavailable")
                file_id = route[1]
                if route[2]:
                    self.respond(200, objects.read(file_id), binary=True)
                    return
                if upload:
                    length = self.headers.get("Content-Length", "")
                    if self.headers.get("Transfer-Encoding") or not length.isascii() or not length.isdigit():
                        raise StorageError(411, "Content length required")
                    size = int(length)
                    if not 1 <= size <= MAX_BYTES:
                        raise StorageError(413, "Invalid file size")
                    if shutil.disk_usage(objects.root).free < 3 * size + 16 * 1024 * 1024:
                        raise StorageError(507,"Storage capacity insufficient")
                    content = self.rfile.read(size)
                    if len(content) != size:
                        raise StorageError(400, "Incomplete file")
                    result = objects.put(file_id, content, self.headers.get_content_type(), self.headers.get("X-Content-SHA256", ""))
                else:
                    result = objects.metadata(file_id)
                self.respond(200, result)
            except (BrokenPipeError, ConnectionResetError):
                return
            except StorageError as error:
                self.respond(error.status, {"error": str(error)})
            except (OSError, ValueError):
                self.respond(503, {"error": "Storage operation unavailable"})

        def do_GET(self):
            self.handle_object(False)

        def do_PUT(self):
            self.handle_object(True)

    service = OriginServer(("127.0.0.1", port), Handler)
    service.slots = threading.BoundedSemaphore(4)
    return service


def defender_scanner(executable, root):
    def scan(content, mime):
        extension = {"application/pdf": ".pdf", "image/jpeg": ".jpg", "image/png": ".png"}[mime]
        with tempfile.NamedTemporaryFile(dir=root, suffix=extension, delete=False) as temporary:
            file = Path(temporary.name)
            try:
                temporary.write(content)
                temporary.close()
                result = subprocess.run(
                    [str(executable), "-Scan", "-ScanType", "3", "-File", str(file), "-DisableRemediation"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=6, check=False, creationflags=subprocess.CREATE_NO_WINDOW,
                )
                return result.returncode == 0 and file.is_file()
            except (OSError, subprocess.TimeoutExpired) as error:
                raise StorageError(503, "Storage scanner unavailable") from error
            finally:
                file.unlink(missing_ok=True)
    return scan


def run():
    local_test = os.environ.get("JAIN_STORAGE_LOCAL_TEST") == "true"
    root = Path(os.environ.get("JAIN_STORAGE_ROOT", "./local-data" if local_test else ""))
    token = os.environ.get("JAIN_STORAGE_TOKEN", "")
    if local_test:
        scan = lambda _content, _mime: True
    else:
        scanner = Path(os.environ.get("JAIN_STORAGE_DEFENDER_PATH", ""))
        if os.name != 'nt' or not root.is_absolute() or not root.is_dir() or not scanner.is_absolute() or not scanner.is_file() or scanner.name.lower() != 'mpcmdrun.exe':
            raise SystemExit("Configure an existing absolute private storage directory and an absolute Microsoft Defender MpCmdRun.exe path.")
        scan = defender_scanner(scanner, root)
    with server(Storage(root, scan), token, int(os.environ.get("JAIN_STORAGE_PORT", "8765"))) as service:
        service.serve_forever()


if __name__ == "__main__":
    run()
