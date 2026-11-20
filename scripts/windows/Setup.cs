using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Reflection;
using System.Diagnostics;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Setup {
    const string Root=@"E:\JainMatrimonialAdmin";
    static SecurityIdentifier Sid(WellKnownSidType t){ return new SecurityIdentifier(t,null); }
    static DirectorySecurity Permissions(bool readable){
        var d=new DirectorySecurity(); d.SetAccessRuleProtection(true,false);
        d.SetOwner(Sid(WellKnownSidType.BuiltinAdministratorsSid));
        foreach(var t in new[]{WellKnownSidType.LocalSystemSid,WellKnownSidType.BuiltinAdministratorsSid,WellKnownSidType.BuiltinUsersSid}){
            bool users=t==WellKnownSidType.BuiltinUsersSid;if(users&&!readable)continue;
            d.AddAccessRule(new FileSystemAccessRule(Sid(t),users?FileSystemRights.ReadAndExecute:FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        }return d;
    }
    static void Trusted(string path,bool folder,bool confidential=false){
        if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new IOException("A linked installation path is unsafe.");
        FileSystemSecurity acl=folder?(FileSystemSecurity)Directory.GetAccessControl(path):File.GetAccessControl(path);
        string owner=acl.GetOwner(typeof(SecurityIdentifier)).Value;
        if(owner!="S-1-5-32-544"&&owner!="S-1-5-18")throw new IOException("Existing installation path is not administrator-owned.");
        foreach(FileSystemAccessRule r in acl.GetAccessRules(true,true,typeof(SecurityIdentifier))){
            string who=r.IdentityReference.Value;
            if(confidential && r.AccessControlType==AccessControlType.Allow && who!="S-1-5-32-544" && who!="S-1-5-18")
                throw new IOException("Existing private storage has an unexpected access rule.");
            if(r.AccessControlType==AccessControlType.Allow&&who!="S-1-5-32-544"&&who!="S-1-5-18"&&
              (r.FileSystemRights&(FileSystemRights.Write|FileSystemRights.Delete|FileSystemRights.DeleteSubdirectoriesAndFiles|FileSystemRights.ChangePermissions|FileSystemRights.TakeOwnership))!=0)
                throw new IOException("Unexpected write permission in the installation directory.");
        }
    }
    static void Tree(string path){
        Trusted(path,true);
        foreach(var f in Directory.GetFiles(path))Trusted(f,false);
        foreach(var d in Directory.GetDirectories(path))Tree(d);
    }
    static string Hash(Stream s){using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(s)).Replace("-","");}
    static void CheckDrive(){
        var e=new DriveInfo("E");
        if(!e.IsReady)throw new IOException("A ready E: drive is required.");
        RequireVolume(e.DriveType,e.DriveFormat,e.AvailableFreeSpace);
    }
    static void RequireVolume(DriveType type,string format,long free){
        if(type!=DriveType.Fixed||format!="NTFS")throw new IOException("A fixed NTFS E: drive is required.");
        if(free<700L*1024*1024)throw new IOException("At least 700 MiB must be free on E:.");
    }
    static bool Installed(){
        using(var k=Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{PRODUCTCODE}"))return k!=null;
    }
    [STAThread] static int Main(string[] args){
        try {
            using(var payload=Assembly.GetExecutingAssembly().GetManifestResourceStream("admin.msi")){
                if(Hash(payload)!="MSIHASH")throw new IOException("Installer payload verification failed.");
                if(args.Length==1&&args[0]=="--verify")return 0;
                if(args.Length!=0)return 2;
                CheckDrive();
                if(MessageBox.Show("Install or repair Jain Matrimonial Admin on E:? Storage enrollment is available after sign-in.","Jain Matrimonial",MessageBoxButtons.OKCancel,MessageBoxIcon.Information)!=DialogResult.OK)return 0;
                Directory.CreateDirectory(Root,Permissions(true));Trusted(Root,true);
                foreach(var n in new[]{"Runtime","StorageServer","Config","Secrets","Logs","State","Sync","Temp","Backups"}){
                    var dir=Path.Combine(Root,n);bool read=n=="Config"||n=="Runtime"||n=="StorageServer"||n=="Temp";
                    Directory.CreateDirectory(dir,Permissions(read));
                    if(n=="Runtime"||n=="StorageServer"||n=="Config")Tree(dir);else Trusted(dir,true,!read);
                }
                var privateTemp=Path.Combine(Root,@"Temp\Installer");
                Directory.CreateDirectory(privateTemp,Permissions(false));Trusted(privateTemp,true,true);Tree(privateTemp);
                string scratch=Path.Combine(Root,@"Temp\Users");
                if(!Directory.Exists(scratch)){
                    var a=Permissions(true);
                    a.AddAccessRule(new FileSystemAccessRule(Sid(WellKnownSidType.BuiltinUsersSid),FileSystemRights.CreateDirectories,AccessControlType.Allow));
                    Directory.CreateDirectory(scratch,a);
                }else if((File.GetAttributes(scratch)&FileAttributes.ReparsePoint)!=0)throw new IOException("Linked scratch directory.");
                foreach(var n in new[]{"admin","storage"}){
                    string cfg=Path.Combine(Root,"Config",n+".json");
                    if(!File.Exists(cfg))File.WriteAllText(cfg,n=="admin"?"{\"api\":\"https://jain-matrimonial-api.avtejasupadhye-9a.workers.dev\"}":"{}");
                }
                var launcher=Path.Combine(Root,"JainMatrimonialAdmin.exe");
                if(File.Exists(launcher))Trusted(launcher,false);
                string msi=Path.Combine(privateTemp,"PRODUCTCODE.msi");
                try{
                    if(File.Exists(msi)){Trusted(msi,false);using(var existing=File.OpenRead(msi))if(Hash(existing)!="MSIHASH")throw new IOException("Cached installer integrity check failed.");}
                    else {
                        var tmp=msi+"."+Guid.NewGuid().ToString("N");
                        try{payload.Position=0;using(var file=new FileStream(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){payload.CopyTo(file);file.Flush(true);}File.Move(tmp,msi);}finally{if(File.Exists(tmp))File.Delete(tmp);}
                    }
                    string cmd="/i \""+msi+"\" /qb! REBOOT=ReallySuppress"+(Installed()?" REINSTALL=ALL REINSTALLMODE=amus":"");
                    using(var p=Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"msiexec.exe"),cmd){UseShellExecute=false})){
                        p.WaitForExit();if(p.ExitCode!=0&&p.ExitCode!=3010)throw new IOException("Windows Installer returned "+p.ExitCode+". Close the Admin application before retrying.");
                    }
                }catch{throw;}
                MessageBox.Show("Installation complete. Open Jain Matrimonial Admin from the Start menu and sign in.","Jain Matrimonial");return 0;
            }
        }catch(Exception ex){MessageBox.Show(ex.Message,"Jain Matrimonial setup",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
}

