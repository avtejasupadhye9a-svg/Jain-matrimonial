"""Assemble the unified installer from matching Windows x64 release inputs."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import uuid
import zipfile
import xml.etree.ElementTree as ET

REPO=Path(__file__).resolve().parents[2]
ROOT=REPO/".local/infra"
NAMESPACE=uuid.UUID("ac64a531-2b6e-49fe-870b-97bc01a2ae6a")
def guid(value):return str(uuid.uuid5(NAMESPACE,value)).upper()
def sha(path):
    with path.open("rb") as f:return hashlib.file_digest(f,"sha256").hexdigest()
def run(args):subprocess.run([str(x) for x in args],check=True,cwd=REPO)
def build(wix,baseline,aot,server,connector,version):
    if REPO.drive.upper()!="E:":raise RuntimeError("Build on E:")
    out=ROOT/("package-"+uuid.uuid4().hex);out.mkdir(parents=True)
    os.environ["TMP"]=os.environ["TEMP"]=str(ROOT/"tmp")
    runtime=out/"Runtime"
    if sha(baseline)!="2fca33da503f97e4ba88425baf34910090f2c78aaf46ac1ec10c29bc2513b025":
        raise ValueError("Unexpected Windows runner archive; review its provenance before updating the pinned digest")
    with zipfile.ZipFile(baseline) as archive:
        for n in archive.namelist():
            if "\\" in n:n=n.replace("\\","/")
            if (runtime/n).resolve().is_relative_to(runtime.resolve()) is False:raise ValueError("Unsafe runtime archive")
        archive.extractall(runtime)
    if sha(runtime/"flutter_windows.dll")!=sha(ROOT/"flutter/bin/cache/artifacts/engine/windows-x64-release/flutter_windows.dll"):
        raise ValueError("Native runner engine does not match the AOT compiler")
    shutil.copyfile(aot/"windows/app.so",runtime/"data/app.so")
    shutil.rmtree(runtime/"data/flutter_assets")
    shutil.copytree(aot/"flutter_assets",runtime/"data/flutter_assets")
    storage=out/"StorageServer";shutil.copytree(server/"runtime",storage)
    shutil.copytree(server/"licenses",storage/"licenses")
    shutil.copyfile(connector,storage/"cloudflared.exe")
    csc=Path(os.environ["SystemRoot"])/"Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    host=out/"JainMatrimonialAdmin.exe"
    run([csc,"/nologo","/target:winexe","/platform:x64","/r:System.ServiceProcess.dll","/r:System.Windows.Forms.dll","/out:"+str(host),REPO/"scripts/windows/AdminHost.cs"])
    files=[host]+sorted(p for d in (runtime,storage) for p in d.rglob("*") if p.is_file())
    product=guid(version+"".join(sha(p) for p in files))
    wx=ET.Element("Wix",xmlns="http://schemas.microsoft.com/wix/2006/wi")
    def sub(p,tag,**attrs):return ET.SubElement(p,tag,attrs)
    prod=sub(wx,"Product",Id=product,UpgradeCode=str(NAMESPACE),Name="Jain Matrimonial Admin",Language="1033",Version=version,Manufacturer="Jain Matrimonial")
    sub(prod,"Package",InstallerVersion="500",Compressed="yes",InstallScope="perMachine",Platform="x64")
    sub(prod,"MajorUpgrade",AllowSameVersionUpgrades="yes",Schedule="afterInstallInitialize",DowngradeErrorMessage="A newer Jain Matrimonial Admin is already installed.")
    sub(prod,"MediaTemplate",EmbedCab="yes",CompressionLevel="high")
    root=sub(prod,"Directory",Id="TARGETDIR",Name="SourceDir")
    start=sub(root,"Directory",Id="ProgramMenuFolder");desk=sub(root,"Directory",Id="DesktopFolder")
    app=sub(root,"Directory",Id="INSTALLFOLDER",Name="JainMatrimonialAdmin")
    sub(prod,"SetDirectory",Id="INSTALLFOLDER",Value=r"E:\JainMatrimonialAdmin")
    dirs={Path("."):app}
    feature=sub(prod,"Feature",Id="Admin",Title="Jain Matrimonial Admin",Level="1")
    def identifier(pre,p):return pre+hashlib.sha256(str(p).encode()).hexdigest()[:32]
    def directory(p):
        if p not in dirs:dirs[p]=sub(directory(p.parent),"Directory",Id=identifier("D",p),Name=p.name)
        return dirs[p]
    for path in files:
        rel=path.relative_to(out);cid=identifier("C",rel)
        comp=sub(directory(rel.parent),"Component",Id=cid,Guid=guid(rel.as_posix()),Win64="yes")
        f=sub(comp,"File",Id=identifier("F",rel),Source=str(path),KeyPath="yes",Name=path.name)
        if path==host:
            for d,i in ((start,"StartShortcut"),(desk,"DesktopShortcut")):
                sub(f,"Shortcut",Id=i,Directory=d.get("Id"),Name="Jain Matrimonial Admin",Advertise="yes",WorkingDirectory="INSTALLFOLDER")
        sub(feature,"ComponentRef",Id=cid)
    sub(prod,"Binary",Id="Manager",SourceFile=str(host))
    seq=sub(prod,"InstallExecuteSequence")
    for name,arg,where,when in [
        ("StopOrigin","--scm-stop",{"Before":"InstallFiles"},"NOT REMOVE"),
        ("StopForRemoval","--scm-stop",{"Before":"RemoveFiles"},'REMOVE="ALL"'),
        ("UnregisterOrigin","--scm-remove",{"Before":"RemoveFiles"},'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE'),
        ("RestartOrigin","--scm-start",{"After":"InstallFiles"},"NOT REMOVE"),
        ("RecoverOrigin","--scm-start",{"Before":"StopOrigin"},"NOT REMOVE")]:
        sub(prod,"CustomAction",Id=name,BinaryKey="Manager",ExeCommand=arg,Execute="rollback" if name=="RecoverOrigin" else "deferred",Impersonate="no",Return="check")
        sub(seq,"Custom",Action=name,**where).text=when
    source=out/"product.wxs";ET.ElementTree(wx).write(source,encoding="utf-8",xml_declaration=True)
    obj=out/"product.wixobj";msi=out/"admin.msi"
    run([wix/"candle.exe","-nologo","-out",obj,source])
    run([wix/"light.exe","-nologo","-sval","-out",msi,obj])
    cs=out/"Setup.cs";cs.write_text((REPO/"scripts/windows/Setup.cs").read_text().replace("MSIHASH",sha(msi).upper()).replace("PRODUCTCODE",product))
    manifest=out/"setup.manifest"
    manifest.write_text('<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0"><trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges><requestedExecutionLevel level="requireAdministrator" uiAccess="false"/></requestedPrivileges></security></trustInfo></assembly>')
    exe=out/"JainMatrimonialAdmin-Setup.exe"
    run([csc,"/nologo","/target:winexe","/platform:x64","/r:System.Windows.Forms.dll","/win32manifest:"+str(manifest),"/resource:"+str(msi)+",admin.msi","/out:"+str(exe),cs])
    dist=REPO/"dist";dist.mkdir(exist_ok=True)
    shutil.copyfile(exe,dist/exe.name)
    (dist/"SHA256SUMS.txt").write_text(sha(exe)+"  "+exe.name+"\n")
    print(str(dist/exe.name),sha(exe))
if __name__=="__main__":
    p=argparse.ArgumentParser()
    for name in ("wix","baseline","aot","server","connector"):p.add_argument("--"+name,type=Path,required=True)
    p.add_argument("--version",default="1.2.0")
    build(**vars(p.parse_args()))

