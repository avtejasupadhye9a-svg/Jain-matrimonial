"""Native Windows SCM entry point. The frozen service never reads test overrides."""
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import secrets
import sys
import time
import subprocess
import tempfile
import threading
import uuid
import urllib.request
import winreg

import servicemanager
import win32crypt
import win32service
import win32serviceutil
from local_storage_service.service import Storage, defender_scanner, server

from local_storage_service import managed

NAME = "JainStorageServer"
STATE = managed.APP / "State"
DATA = Path(r"E:\JainMatrimonialStorage")


def machine():
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Cryptography",
                        0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as key:
        return winreg.QueryValueEx(key, "MachineGuid")[0]


def credentials(state):
    # CRYPTPROTECT_UI_FORBIDDEN. The installer protects UTF-8 bytes using LocalMachine.
    if state == managed.APP / "State":
        item=managed.sealed(managed.SECRET)
        return item["token"],str(uuid.UUID(item["id"]))
    _, secret = win32crypt.CryptUnprotectData((state / "origin.dpapi").read_bytes(), None, None, None, 1)
    binding = json.loads((state / "designation.json").read_text(encoding="utf-8-sig"))
    if binding["machine"] != machine():
        raise ValueError("Origin enrolled on a different PC")
    return secret.decode("ascii"), str(uuid.UUID(binding["origin"]))


def scanner():
    base = Path(os.environ["ProgramData"]) / "Microsoft/Windows Defender/Platform"
    candidates = sorted((p for p in base.glob("4.*") if p.is_dir()),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    candidates.append(Path(os.environ["ProgramFiles"]) / "Windows Defender")
    for directory in candidates:
        executable = directory / "MpCmdRun.exe"
        if executable.is_file():
            return executable
    raise RuntimeError("Microsoft Defender unavailable")


class OriginService(win32serviceutil.ServiceFramework):
    _svc_name_ = NAME
    _svc_display_name_ = "Jain Matrimonial Storage Server"

    def __init__(self, args):
        super().__init__(args)
        self.stopping = threading.Event()

    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING, waitHint=30000)
        self.stopping.set()

    SvcShutdown = SvcStop

    def SvcRun(self):
        handler = None
        try:
            log = logging.getLogger("storage")
            log.setLevel(logging.INFO)
            installed = STATE == managed.APP / "State"
            logs = managed.APP/"Logs" if installed else STATE
            handler = RotatingFileHandler(logs / "storage.log", maxBytes=1_000_000, backupCount=4)
            class EventFormatter(logging.Formatter):
                def format(self, record):
                    return json.dumps({"time":self.formatTime(record),"level":record.levelname,"event":record.getMessage()})
            handler.setFormatter(EventFormatter())
            log.addHandler(handler)
            token, origin = credentials(STATE)
            root = managed.vault() if installed else DATA
            if not root.is_dir():
                raise RuntimeError("Missing permanent volume")
            scan = defender_scanner(scanner(), root/"Quarantine" if installed else DATA)
            if not scan(b"%PDF-1.4\n%%EOF\n", "application/pdf"):
                raise RuntimeError("Scanner readiness check failed")
            class Documents(Storage):
                def path(self,file_id):
                    new=super().path(file_id)
                    legacy=root/new.name
                    return legacy if installed and legacy.is_file() else new
            stores = {"nonces":managed.APP/"Sync/nonces.sqlite","photos":Storage(root/"Photos",scan)} if installed else {}
            with server(Documents(root/"Documents" if installed else DATA, scan), token, origin_id=origin, **stores) as host:
                host.timeout = 0.4
                host.audit_log = log
                self.ReportServiceStatus(win32service.SERVICE_RUNNING)
                log.info("Service ready")
                child=None; next_start=0
                try:
                    while not self.stopping.is_set():
                        if installed and time.monotonic()>=next_start:
                            next_start=time.monotonic()+30
                            if managed.service_status("cloudflared"):
                                if managed.service_status("cloudflared")==win32service.SERVICE_STOPPED:
                                    try:win32serviceutil.StartService("cloudflared")
                                    except Exception:log.warning("Connector start unavailable")
                            elif child is None or child.poll() is not None:
                                connector=managed.sealed(managed.SECRET).get("connector")
                                if connector:
                                    child=subprocess.Popen([str(managed.APP/"StorageServer/cloudflared.exe"),"tunnel","--no-autoupdate","run"],
                                        env={**os.environ,"TUNNEL_TOKEN":connector,"TEMP":str(managed.APP/"Temp"),"TMP":str(managed.APP/"Temp")},
                                        stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
                        host.handle_request()
                finally:
                    if child and child.poll() is None:child.terminate();child.wait(10)
            log.info("Service stopped")
        except Exception as error:
            # Exception messages can contain paths or sensitive input.
            servicemanager.LogErrorMsg("Storage service failed: " + type(error).__name__)
            logging.getLogger("storage").error("Service failed (%s)", type(error).__name__)
            raise
        finally:
            if handler is not None:
                logging.getLogger("storage").removeHandler(handler)
                handler.close()


def smoke():
    """Exercise the packaged runtime on an ephemeral port using disposable state."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        token = secrets.token_hex(32)
        origin = str(uuid.uuid4())
        (root / "origin.dpapi").write_bytes(win32crypt.CryptProtectData(token.encode(), None, None, None, None, 5))
        (root / "designation.json").write_text(json.dumps({"machine": machine(), "origin": origin}))
        assert credentials(root) == (token, origin)
        with server(Storage(root, lambda *_: False), token, 0, origin_id=origin) as host:
            thread = threading.Thread(target=host.serve_forever)
            thread.start()
            try:
                url = "http://127.0.0.1:%d/health" % host.server_port
                request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "X-Jain-Origin": origin})
                with urllib.request.urlopen(request, timeout=4) as response:
                    assert response.headers["X-Jain-Origin"] == origin and json.load(response)["status"] == "ok"
            finally:
                host.shutdown()
                thread.join()


if __name__ == "__main__":
    if sys.argv[1:] != ["--self-test"]:
        scratch=str(managed.APP/"State")
        os.environ["TMP"]=os.environ["TEMP"]=scratch
        tempfile.tempdir=scratch
    if sys.argv[1:] == ["--self-test"]:
        smoke()
    elif len(sys.argv) in (3,4) and sys.argv[1]=="--manage":
        import ctypes
        if not ctypes.windll.shell32.IsUserAnAdmin() or Path(sys.executable).resolve()!=managed.EXE:
            sys.exit(3)
        try:
            managed.manage(sys.argv[2],sys.argv[3] if len(sys.argv)>3 else None)
        except Exception as error:
            # Keep the GUI failure sanitized, including HTTP and credential errors.
            import urllib.error
            message = str(error) if type(error) is ValueError else "Storage operation failed ("+type(error).__name__+")."
            ctypes.windll.user32.MessageBoxW(None,message,"Jain Matrimonial Storage",16)
            sys.exit(1)
    elif len(sys.argv) == 1:
        servicemanager.Initialize()
        servicemanager.PrepareToHostSingle(OriginService)
        servicemanager.StartServiceCtrlDispatcher()
    else:
        sys.exit(2)

