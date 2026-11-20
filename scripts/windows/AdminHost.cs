using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Security.Principal;
using System.Security.AccessControl;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class AdminHost {
    internal const string Root=@"E:\JainMatrimonialAdmin";
    internal static string ServiceExe { get { return Path.Combine(Root,@"StorageServer\JainStorageServer.exe"); } }
    static string Status(string name) {
        try { using(var s=new ServiceController(name)) return s.Status.ToString(); }
        catch(InvalidOperationException) { return "Not installed"; }
    }
    static bool ManagedService() {
        using(var k=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\JainStorageServer")) {
            return k!=null && String.Equals(Convert.ToString(k.GetValue("ImagePath")).Trim('"'),ServiceExe,StringComparison.OrdinalIgnoreCase);
        }
    }
    [STAThread] static int Main(string[] args) {
        try {
            if(args.Length==1 && args[0]=="--status"){
                Console.WriteLine(Status("JainStorageServer")+"|"+Status("cloudflared")); return 0;
            }
            if(args.Length==1 && args[0].StartsWith("--scm-",StringComparison.Ordinal)){
                if(!ManagedService())return 0;
                using(var s=new ServiceController("JainStorageServer")){
                    if(args[0]=="--scm-start"){if(s.Status==ServiceControllerStatus.Stopped)s.Start();s.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(50));}
                    else if(args[0]=="--scm-stop" || args[0]=="--scm-remove"){
                        if(s.Status!=ServiceControllerStatus.Stopped){s.Stop();s.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(50));}
                        if(args[0]=="--scm-remove")using(var p=Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"sc.exe"),"delete JainStorageServer"){UseShellExecute=false,CreateNoWindow=true})){p.WaitForExit();return p.ExitCode;}
                    }else return 2;
                }
                return 0;
            }
            if(args.Length>=2 && args[0]=="--manage"){
                string action=args[1];
                if(!Regex.IsMatch(action,@"\A(prepare|redeem|repair|restart|stop|logs|location|backup|external|restore|rollback)\z"))return 2;
                bool ticket=action=="redeem"||action=="restore"||action=="rollback";
                if(args.Length!=(ticket?3:2) || (ticket && !Regex.IsMatch(args[2],action!="restore"?@"\A[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}\z":@"\A[a-f0-9]{64}\z")))return 2;
                using(var p=Process.Start(new ProcessStartInfo(ServiceExe,"--manage "+action+(ticket?" "+args[2]:"")){UseShellExecute=true,Verb="runas",WorkingDirectory=Path.GetDirectoryName(ServiceExe)})){p.WaitForExit();return p.ExitCode;}
            }
            if(args.Length!=0)return 2;
            var runtime=Path.Combine(Root,"Runtime");
            var start=new ProcessStartInfo(Path.Combine(runtime,"jain_admin.exe")){WorkingDirectory=runtime,UseShellExecute=false};
            var sid=WindowsIdentity.GetCurrent().User;
            var scratch=Path.Combine(Root,@"Temp\Users",sid.Value);
            if(!Directory.Exists(scratch)){
                var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);acl.SetOwner(sid);
                foreach(var principal in new[]{sid,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)}){
                    acl.AddAccessRule(new FileSystemAccessRule(principal,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
                }
                Directory.CreateDirectory(scratch,acl);
            }
            if((File.GetAttributes(scratch)&FileAttributes.ReparsePoint)!=0||!Directory.GetAccessControl(scratch).GetOwner(typeof(SecurityIdentifier)).Equals(sid))throw new IOException("Unsafe user scratch directory.");
            start.EnvironmentVariables["TMP"]=start.EnvironmentVariables["TEMP"]=scratch;
            Process.Start(start);return 0;
        }catch(Exception ex){MessageBox.Show(ex.Message,"Jain Matrimonial",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
}

