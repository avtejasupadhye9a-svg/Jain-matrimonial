"""Machine-local enrollment and maintenance. Only fixed actions can be elevated."""
import hashlib
import hmac
import subprocess
import logging
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import time
import uuid
import urllib.request
import win32event
import win32api
import win32crypt
import win32service
import win32serviceutil
import win32security

import pywintypes
from contextlib import closing

APP = Path(r"E:\JainMatrimonialAdmin")
DATA = Path(r"E:\JainMatrimonialStorage")
SERVICE = "JainStorageServer"
BASE = "https://jain-matrimonial-api.avtejasupadhye-9a.workers.dev"
EXE = APP / "StorageServer/JainStorageServer.exe"
SECRET = APP / "Secrets/origin-credentials.dat"
PUBLIC = APP / "Config/storage.json"


def safe(path):
    for p in (path, *path.parents):
        if p.exists() and (p.is_symlink() or p.is_junction() or p.stat().st_file_attributes & 1024):
            raise ValueError("A linked path is unsupported")
    return path


def atomic(path, data):
    safe(path)
    tmp = path.with_name(uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("xb") as out:
            out.write(data)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def sealed(path, value=None):
    if value is not None:
        data = json.dumps(value).encode()
        atomic(path,win32crypt.CryptProtectData(data,None,None,None,None,5))
    else:
        return json.loads(win32crypt.CryptUnprotectData(safe(path).read_bytes(),None,None,None,1)[1])


def info():
    return json.loads(safe(PUBLIC).read_bytes().decode("utf-8-sig")) if PUBLIC.is_file() else {}


def update(**fields):
    atomic(PUBLIC,json.dumps({**info(),**fields}).encode())


PRIVATE_SDDL = "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)"
TRUSTED_OWNERS = {"S-1-5-18", "S-1-5-32-544"}


def check_private(path):
    safe(path)
    sd = win32security.GetNamedSecurityInfo(
        str(path), win32security.SE_FILE_OBJECT,
        win32security.OWNER_SECURITY_INFORMATION | win32security.DACL_SECURITY_INFORMATION)
    owner = win32security.ConvertSidToStringSid(sd.GetSecurityDescriptorOwner())
    acl = sd.GetSecurityDescriptorDacl()
    if owner not in TRUSTED_OWNERS or acl is None or any(
            win32security.ConvertSidToStringSid(acl.GetAce(i)[2]) not in TRUSTED_OWNERS
            for i in range(acl.GetAceCount())):
        raise ValueError("Existing storage requires private NTFS ownership and permissions")
    if path.is_file() and path.stat().st_nlink != 1:
        raise ValueError("Linked permanent files require owner review")


def private_dir(path):
    safe(path)
    if not path.exists():
        sa = pywintypes.SECURITY_ATTRIBUTES()
        sa.SECURITY_DESCRIPTOR = win32security.ConvertStringSecurityDescriptorToSecurityDescriptor(PRIVATE_SDDL, 1)
        import win32file
        win32file.CreateDirectory(str(path), sa)
    check_private(path)


def verify_private_tree(root):
    for entry in root.iterdir():
        check_private(entry)
        if entry.is_dir():
            verify_private_tree(entry)


def vault():
    p=Path(info().get("location",str(DATA)))
    if p!=DATA and (p.parent!=DATA/"Locations" or not re.fullmatch("[A-Za-z0-9_-]{1,64}",p.name)):
        raise ValueError("Unsupported permanent folder")
    return safe(p)


def prepare_data():
    safe(DATA)
    if not DATA.exists() or not any(DATA.iterdir()):
        # The original, empty folder can be adopted. Never recurse over existing user files.
        safe(DATA)
        if DATA.exists():
            sd=win32security.ConvertStringSecurityDescriptorToSecurityDescriptor(PRIVATE_SDDL,1)
            win32security.SetNamedSecurityInfo(str(DATA),1,0x80000005,sd.GetSecurityDescriptorOwner(),None,sd.GetSecurityDescriptorDacl(),None)
    private_dir(DATA)
    target=vault()
    private_dir(target)
    for n in ("Documents","Photos","Pending","Quarantine"):
        private_dir(target/n)


def service_status(name):
    try:
        return win32serviceutil.QueryServiceStatus(name)[1]
    except pywintypes.error as err:
        if err.winerror==1060:
            return 0
        raise


def stop():
    status=service_status(SERVICE)
    if status:
        scm=win32service.OpenSCManager(None,None,win32service.SC_MANAGER_CONNECT)
        try:
            svc=win32service.OpenService(scm,SERVICE,win32service.SERVICE_QUERY_CONFIG)
            try:path=Path(win32service.QueryServiceConfig(svc)[3].strip('"'))
            finally:win32service.CloseServiceHandle(svc)
        finally:win32service.CloseServiceHandle(scm)
        if path not in (EXE,Path(r"E:\JainStorageServer\runtime\JainStorageServer.exe")):
            raise ValueError("Service name is in use by another application")
    if status and status!=win32service.SERVICE_STOPPED:
        win32serviceutil.StopService(SERVICE)
        win32serviceutil.WaitForServiceStatus(SERVICE,win32service.SERVICE_STOPPED,40)


def configure():
    import subprocess
    exe=str(safe(EXE))
    scm=win32service.OpenSCManager(None,None,win32service.SC_MANAGER_ALL_ACCESS)
    try:
        if service_status(SERVICE):
            svc=win32service.OpenService(scm,SERVICE,win32service.SERVICE_ALL_ACCESS)
            path=win32service.QueryServiceConfig(svc)[3].strip('"')
            if os.path.normcase(path)==os.path.normcase(r"E:\JainStorageServer\runtime\JainStorageServer.exe"):
                win32service.ChangeServiceConfig(svc,win32service.SERVICE_NO_CHANGE,win32service.SERVICE_AUTO_START,win32service.SERVICE_NO_CHANGE,'"'+exe+'"',None,0,None,None,None,None)
            elif os.path.normcase(path)!=os.path.normcase(exe):
                win32service.CloseServiceHandle(svc)
                raise ValueError("An earlier storage service must be retired before activation")
        else:
            svc=win32service.CreateService(scm,SERVICE,"Jain Matrimonial Storage Server",
                win32service.SERVICE_ALL_ACCESS,win32service.SERVICE_WIN32_OWN_PROCESS,win32service.SERVICE_AUTO_START,
                win32service.SERVICE_ERROR_NORMAL,'"'+exe+'"',None,0,None,None,None)
        try:
            win32service.ChangeServiceConfig(svc,win32service.SERVICE_NO_CHANGE,win32service.SERVICE_AUTO_START,win32service.SERVICE_NO_CHANGE,None,None,0,None,None,None,None)
        finally:
            win32service.CloseServiceHandle(svc)
    finally:
        win32service.CloseServiceHandle(scm)
    sc=str(Path(os.environ["SystemRoot"])/"System32/sc.exe")
    for args in (["failure",SERVICE,"reset=","86400","actions=","restart/10000/restart/30000/restart/60000"],["failureflag",SERVICE,"1"]):
        subprocess.run([sc,*args],check=True,capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW)
    if service_status(SERVICE)!=win32service.SERVICE_RUNNING:
        win32serviceutil.StartService(SERVICE)
        win32serviceutil.WaitForServiceStatus(SERVICE,win32service.SERVICE_RUNNING,45)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args):
        return None


def worker_http():
    opener = urllib.request.build_opener(NoRedirect())
    opener.addheaders = [("User-Agent", "JainMatrimonialStorage/1.2.2")]
    return opener


def enroll(ticket):
    seed=sealed(APP/"Secrets/enrollment.dat")["seed"]
    missing=service_status("cloudflared")==0
    req=urllib.request.Request(BASE+"/storage/enrollment/claim",json.dumps({"id":ticket,"seed":seed,"connectorNeeded":missing}).encode(),{"Content-Type":"application/json"})
    with worker_http().open(req,timeout=25) as res:
        data=json.load(res)["data"]
    if data["id"]!=ticket or not re.fullmatch("[a-f0-9]{64}",data["credential"]):
        raise ValueError("Invalid enrollment response")
    stop()
    if SECRET.is_file():
        old=sealed(SECRET)
        prior=APP/"Secrets"/(str(uuid.UUID(old["id"]))+".previous")
        if not prior.exists():atomic(prior,SECRET.read_bytes())
    sealed(SECRET,{"id":ticket,"token":data["credential"],"connector":data.get("connector")})
    update(origin=ticket)
    configure()


def checksum(path):
    with safe(path).open("rb") as f:
        return hashlib.file_digest(f,"sha256").hexdigest()


def cloud_backup(kind,arg):
    cred=sealed(SECRET)
    nonce=str(uuid.uuid4()); stamp=int(time.time())
    raw="|".join([cred["id"],nonce,str(stamp),kind,arg]).encode()
    proof=hmac.new(cred["token"].encode(),raw,hashlib.sha256).hexdigest()
    body={"id":cred["id"],"nonce":nonce,"stamp":stamp,"kind":kind,"arg":arg,"proof":proof}
    req=urllib.request.Request(BASE+"/storage/origin/backup",json.dumps(body).encode(),{"Content-Type":"application/json"})
    with worker_http().open(req,timeout=20) as res:
        return json.load(res)["data"]


def snapshot(folder,source=None,register=True):
    source=source or vault()
    safe(folder)
    private_dir(folder)
    records=[]
    for group in ["Documents","Photos",""]:
        for f in (source/group).iterdir():
            if group=="" and f.name in {"Documents","Photos","Pending","Quarantine","Locations"}: continue
            if not f.is_file() or str(uuid.UUID(f.name))!=f.name:raise ValueError("Unexpected storage entry")
            dest=folder/(group or "Legacy")/f.name
            dest.parent.mkdir(exist_ok=True)
            sha=checksum(f)
            if not dest.exists() or checksum(dest)!=sha:
                temp=dest.with_name(uuid.uuid4().hex+".partial")
                with safe(f).open("rb") as src,safe(temp).open("xb") as output:
                    shutil.copyfileobj(src,output)
                    output.flush()
                    os.fsync(output.fileno())
                if checksum(temp)!=sha:raise ValueError("Backup interrupted")
                os.replace(temp,safe(dest))
            if checksum(dest)!=sha:raise ValueError("Backup verification failed")
            records.append({"file":f.name,"group":group or "Legacy","sha256":sha})
    manifest={"version":1,"files":records,"machine":os.environ["COMPUTERNAME"],"origin":info().get("origin"),"location":str(source)}
    if register:
        local={r["file"]:r["sha256"] for r in records}
        for kind,key in (("files","id"),("receipts","ticket")):
            cursor=""; path=folder/(kind+".jsonl")
            temp=folder/(uuid.uuid4().hex+".partial")
            with safe(temp).open("x",encoding="utf8") as out:
                while True:
                    items=cloud_backup(kind,cursor)["items"]
                    for item in items:
                        if kind=="files" and item["state"]=="confirmed" and local.get(item["id"])!=item["sha256"]:
                            raise ValueError("Backup is missing confirmed permanent files")
                        out.write(json.dumps(item)+"\n")
                    if len(items)<100:break
                    cursor=items[-1][key]
            os.replace(temp,safe(path))
            manifest[kind+"Hash"]=checksum(path)
        atomic(folder/"recovery.txt",b"Use Settings > Storage Infrastructure > Restore verified backup on the replacement PC. Enable the main server after restoring.")
    atomic(folder/"manifest.json",json.dumps(manifest).encode())
    if register: cloud_backup("confirm",checksum(folder/"manifest.json"))
    if register:update(lastBackup=time.strftime("%Y-%m-%d %H:%M"),backupHash=checksum(folder/"manifest.json"))


def restore(folder,target_root=None,expected=None):
    target_root=target_root or vault()
    raw=safe(folder/"manifest.json").read_bytes()
    if expected and not hmac.compare_digest(hashlib.sha256(raw).hexdigest(),expected):
        raise ValueError("Backup does not match the recorded cloud manifest")

    manifest=json.loads(raw)
    if manifest.get("version")!=1:raise ValueError("Unsupported backup")
    for kind in ("files","receipts"):
        if kind+"Hash" in manifest and checksum(folder/(kind+".jsonl"))!=manifest[kind+"Hash"]:
            raise ValueError("Backup metadata integrity failure")
    for row in manifest["files"]:
        group=row["group"];name=row["file"]
        if group not in ("Documents","Photos","Legacy") or str(uuid.UUID(name))!=name:raise ValueError("Unsafe manifest")
        source=folder/group/name
        target=target_root/(group if group!="Legacy" else "")/name
        if checksum(source)!=row["sha256"]:raise ValueError("Backup checksum mismatch")
        if target.exists():
            if checksum(target)!=row["sha256"]:raise ValueError("Existing object differs")
            continue
        copy=target_root/"Pending"/(uuid.uuid4().hex+".restore")
        try:
            shutil.copyfile(source,copy)
            if checksum(copy)!=row["sha256"]:raise ValueError("Restore verification failed")
            os.rename(copy,safe(target))
        finally:copy.unlink(missing_ok=True)


def manage(action,ticket=None):
    lock=win32event.CreateMutex(None,False,r"Global\JainStorageServerMaintenance")
    try:
        if win32event.WaitForSingleObject(lock,0) not in (0,128):raise ValueError("Another maintenance operation is running")
        try:return _manage(action,ticket)
        finally:win32event.ReleaseMutex(lock)
    finally:win32api.CloseHandle(lock)


def _manage(action, ticket=None):
    from tkinter import filedialog, Tk
    if action=="prepare":
        prepare_data()
        verify_private_tree(DATA)
        seed=secrets.token_hex(32)
        sealed(APP/"Secrets/enrollment.dat",{"seed":seed})
        update(commitment=hashlib.sha256(seed.encode()).hexdigest(),machine=os.environ["COMPUTERNAME"])
    elif action=="redeem":
        if str(uuid.UUID(ticket))!=ticket:raise ValueError("Invalid enrollment ID")
        enroll(ticket)
    elif action in ("repair","restart"):
        if not SECRET.is_file():raise ValueError("Enroll this PC first")
        if action=="restart":stop()
        configure()
    elif action=="rollback":
        restored=sealed(APP/"Secrets"/(str(uuid.UUID(ticket))+".previous"))
        if restored["id"]!=ticket:raise ValueError("Previous origin identity mismatch")
        stop();sealed(SECRET,restored);update(origin=ticket);configure()
    elif action=="stop":stop()
    elif action=="logs":
        from tkinter.scrolledtext import ScrolledText
        view=Tk();view.title("Jain Matrimonial storage log");box=ScrolledText(view,width=90,height=22);box.pack()
        log=APP/"Logs/storage.log"
        box.insert("end",log.read_text(errors="replace")[-16000:] if log.exists() else "No service events yet.")
        box.configure(state="disabled");view.mainloop()
    elif action=="location":
        prepare_data()
        private_dir(DATA/"Locations")
        from tkinter import simpledialog
        dialog=Tk();dialog.withdraw()
        try:name=simpledialog.askstring("Storage location","New folder name under E:\\JainMatrimonialStorage\\Locations",parent=dialog)
        finally:dialog.destroy()
        if not name:return
        if not re.fullmatch("[A-Za-z0-9_-]{1,64}",name):raise ValueError("Use letters, digits, hyphen or underscore")
        dest=DATA/"Locations"/name
        if dest.exists():raise ValueError("Select a new storage folder")
        running=service_status(SERVICE)==win32service.SERVICE_RUNNING
        try:
            stop(); staging=APP/"Backups"/("Move-"+uuid.uuid4().hex)
            snapshot(staging,register=False);private_dir(dest)
            for n in ("Documents","Photos","Pending","Quarantine"):private_dir(dest/n)
            restore(staging,dest,checksum(staging/"manifest.json"))
            update(location=str(dest))
        finally:
            if running:configure()

    elif action in ("backup","external","restore"):
        prepare_data()
        if action=="backup":
            parent=APP/"Backups"
        else:
            root=Tk();root.withdraw()
            try:selected=filedialog.askdirectory(parent=root,initialdir=str(APP/"Backups"),title="Select backup drive or verified restore folder")
            finally:root.destroy()
            if not selected:return
            parent=Path(selected)
        running=service_status(SERVICE)==win32service.SERVICE_RUNNING
        try:
            if running:stop()
            if action in ("backup","external"):
                safe(parent)
                if action=="external" and parent.drive.lower() in (DATA.drive.lower(),os.environ["SystemDrive"].lower()):
                    raise ValueError("Select a separate external NTFS drive")
                working=parent/("Pending-"+str(uuid.UUID(info()["origin"])))
                snapshot(working)
                os.rename(working,parent/("Backup-"+time.strftime("%Y%m%d-%H%M%S")+"-"+uuid.uuid4().hex[:6]))
            else:
                if not re.fullmatch("[a-f0-9]{64}",ticket or ""):raise ValueError("Select a cloud-verified backup")
                restore(parent,expected=ticket)
        finally:
            if running:configure()
    else:raise ValueError("Unknown operation")

