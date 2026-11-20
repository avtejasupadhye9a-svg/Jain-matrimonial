"""Disposable SCM test entry. Excluded from release builds."""
from pathlib import Path
import sys
import secrets
import uuid
import servicemanager
from local_storage_service import windows_host as host, managed

root=Path(sys.executable).resolve().parent
if root.parent!=Path("E:/") or not root.name.startswith("JainStorageQA-"):
    raise RuntimeError("Disposable test installation required")
managed.APP=root
managed.DATA=root/"Objects"
managed.PUBLIC=root/"Config/storage.json"
managed.SECRET=root/"Secrets/origin-credentials.dat"
host.STATE=root/"State"
host.DATA=managed.DATA
host.OriginService._svc_name_="JainStorageAcceptanceQA"
host.OriginService._svc_display_name_="Jain Storage disposable acceptance"
for directory in ["Objects","Objects/Documents","Objects/Photos","Objects/Quarantine","State","Config","Logs","Secrets","Sync"]:
    (root/directory).mkdir(exist_ok=True)
if not managed.SECRET.exists():
    managed.sealed(managed.SECRET,{"id":str(uuid.uuid4()),"token":secrets.token_hex(32)})
# This standalone fixture has no connector and can only use an ephemeral loopback port.
managed.service_status=lambda name: host.win32service.SERVICE_RUNNING if name=="cloudflared" else 0
original=host.server
def isolated(*args,**kwargs):
    result=original(*args,port=0,**kwargs)
    (root/"port.txt").write_text(str(result.server_port))
    return result
host.server=isolated
servicemanager.Initialize()
servicemanager.PrepareToHostSingle(host.OriginService)
servicemanager.StartServiceCtrlDispatcher()

