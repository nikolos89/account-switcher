param(
  [ValidateSet('Current','Save','Plan','Launch','Switch','SelfTest')][string]$Action = 'Current',
  [Parameter(Mandatory)][string]$DataRoot,
  [string]$ProfileId,
  [string]$Label,
  [string]$AppExe,
  [int]$ExpectedProcessId,
  [string]$ExpectedStartTicks
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$entropy = $utf8.GetBytes('Antigravity.LocalAccountPanel.v1')
Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AccountPanelCredentials {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct NativeCredential {
    public uint Flags, Type;
    public string TargetName, Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint CredentialBlobSize;
    public IntPtr CredentialBlob;
    public uint Persist, AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias, UserName;
  }
  public class Entry {
    public string Target {get;set;}
    public string UserName {get;set;}
    public uint Persist {get;set;}
    public byte[] Blob {get;set;}
  }
  [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredRead(string target, uint type, uint flags, out IntPtr entry);
  [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredWrite(ref NativeCredential entry, uint flags);
  [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CredDelete(string target, uint type, uint flags);
  [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);
  public static Entry Read(string target) {
    IntPtr ptr;
    if (!CredRead(target,1,0,out ptr)) {
      int code=Marshal.GetLastWin32Error();
      if(code==1168) return null;
      throw new Win32Exception(code);
    }
    try {
      var entry=Marshal.PtrToStructure<NativeCredential>(ptr);
      if(entry.CredentialBlobSize>1048576) throw new Exception("Unexpected credential size");
      byte[] blob=new byte[entry.CredentialBlobSize];
      Marshal.Copy(entry.CredentialBlob,blob,0,blob.Length);
      return new Entry {Target=target,UserName=entry.UserName,Persist=entry.Persist,Blob=blob};
    } finally { CredFree(ptr); }
  }
  public static void Write(Entry entry) {
    IntPtr blob=Marshal.AllocHGlobal(entry.Blob.Length);
    try {
      Marshal.Copy(entry.Blob,0,blob,entry.Blob.Length);
      var native=new NativeCredential {Type=1,TargetName=entry.Target,UserName=entry.UserName,
        Persist=entry.Persist,CredentialBlobSize=(uint)entry.Blob.Length,CredentialBlob=blob};
      if(!CredWrite(ref native,0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally { Marshal.FreeHGlobal(blob); }
  }
  public static void DeleteTest(string target) {
    if(!target.StartsWith("Codex.AccountPanel.SelfTest.")) throw new Exception("Invalid test target");
    if(!CredDelete(target,1,0) && Marshal.GetLastWin32Error()!=1168)
      throw new Win32Exception(Marshal.GetLastWin32Error());
  }
}
public static class AccountPanelWorker {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct StartupInfo {
    public uint cb; public string reserved, desktop, title;
    public uint x,y,xSize,ySize,xCountChars,yCountChars,fillAttribute,flags;
    public ushort showWindow,reserved2Size; public IntPtr reserved2,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct ProcessInfo { public IntPtr process,thread; public uint processId,threadId; }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern bool CreateProcessW(string application,System.Text.StringBuilder command,IntPtr processAttributes,
    IntPtr threadAttributes,bool inheritHandles,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo info);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  static string Quote(string value) {
    var result=new System.Text.StringBuilder("\""); int slashes=0;
    foreach(char c in value) {
      if(c=='\\') {slashes++;continue;}
      if(c=='\"') {result.Append('\\',slashes*2+1);result.Append(c);slashes=0;continue;}
      result.Append('\\',slashes);slashes=0;result.Append(c);
    }
    result.Append('\\',slashes*2);result.Append('"');return result.ToString();
  }
  public static uint Launch(string executable,string[] args,string directory) {
    var command=new System.Text.StringBuilder(Quote(executable));
    foreach(string arg in args) command.Append(' ').Append(Quote(arg));
    var startup=new StartupInfo {cb=(uint)Marshal.SizeOf<StartupInfo>(),flags=1,showWindow=0};
    ProcessInfo info;
    // A bounded restart worker must survive the app's own child-process job.
    // If the job disallows this, fail before closing or modifying the app.
    if(!CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,false,
      0x08000000u|0x01000000u|0x00000200u,IntPtr.Zero,directory,ref startup,out info))
      throw new Win32Exception(Marshal.GetLastWin32Error());
    try {return info.processId;} finally {CloseHandle(info.thread);CloseHandle(info.process);}
  }
}
'@

function Write-JsonAtomic([string]$Path, $Value) {
  $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 15 -Compress), $utf8)
    [IO.File]::Move($temp, $Path, $true)
  } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-Identity($Entry) {
  if ($null -eq $Entry) { throw 'No Antigravity sign-in was found in Windows Credential Manager. Sign in to the app first.' }
  $payload = $utf8.GetString($Entry.Blob) | ConvertFrom-Json -AsHashtable
  $token = if ($payload.token -is [System.Collections.IDictionary]) { $payload.token } else { $payload }
  $claims = @{}
  if ($token.id_token) {
    $part = ([string]$token.id_token).Split('.')[1].Replace('-','+').Replace('_','/')
    $part = $part.PadRight($part.Length + ((4 - $part.Length % 4) % 4), '=')
    try { $claims = $utf8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json -AsHashtable } catch { $claims = @{} }
  }
  $email = @($claims.email, $payload.id_token_email, $token.email, $payload.email) | Where-Object { $_ -is [string] -and $_ -match '^[^\s@]+@[^\s@]+\.[^\s@]+$' } | Select-Object -First 1
  if (-not $email) { throw 'Could not identify the account email. Sign in through Google in Antigravity and try again.' }
  if (-not $token.refresh_token) { throw 'No reusable sign-in data was found. Sign in to Antigravity again.' }
  $name = if ($claims.name) { [string]$claims.name } else { $email.Split('@')[0] }
  return @{ email = $email.ToLowerInvariant(); name = $name }
}
function Get-Index {
  $path = Join-Path $DataRoot 'profiles.json'
  if (-not [IO.File]::Exists($path)) { return @{ version=1; profiles=@() } }
  $index = [IO.File]::ReadAllText($path,$utf8) | ConvertFrom-Json -AsHashtable
  if ($index.version -ne 1 -or $null -eq $index.profiles) { throw 'Could not read the profile index. No data was changed.' }
  return $index
}
function Initialize-PrivateDirectory {
  [IO.Directory]::CreateDirectory($DataRoot) | Out-Null
  $directory=[IO.DirectoryInfo]::new($DataRoot)
  if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The private profile directory permissions could not be verified. No data was changed.' }
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
  $system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  # Set only the DACL. Do not request ownership or audit privileges.
  $acl=[Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true,$false)
  foreach($principal in @($sid,$system)) {
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
  }
  [IO.FileSystemAclExtensions]::SetAccessControl($directory,$acl)
  $actual=[IO.FileSystemAclExtensions]::GetAccessControl($directory)
  $rules=@($actual.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
  if (-not $actual.AreAccessRulesProtected -or $rules.Count -ne 2) { throw 'The private profile directory permissions could not be verified. No data was changed.' }
  foreach($rule in $rules) {
    if ($rule.IdentityReference.Value -notin @($sid.Value,$system.Value) -or $rule.AccessControlType -ne 'Allow' -or ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne [Security.AccessControl.FileSystemRights]::FullControl) {
      throw 'The private profile directory permissions could not be verified. No data was changed.'
    }
  }
}

function Lock-Vault {
  Initialize-PrivateDirectory
  try { return [IO.File]::Open((Join-Path $DataRoot 'operation.lock'),'OpenOrCreate','ReadWrite','None') }
  catch { throw 'Another operation is running. Wait for it to finish.' }
}
function Protect-Entry($Entry) {
  $json = @{target=$Entry.Target; userName=$Entry.UserName; persist=$Entry.Persist; blob=[Convert]::ToBase64String($Entry.Blob)} | ConvertTo-Json -Compress
  return [Security.Cryptography.ProtectedData]::Protect($utf8.GetBytes($json),$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
}
function Unprotect-Entry([byte[]]$Bytes) {
  $clear = [Security.Cryptography.ProtectedData]::Unprotect($Bytes,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
  try {
    $value = $utf8.GetString($clear) | ConvertFrom-Json -AsHashtable
    if ($value.target -ne 'gemini:antigravity') { throw 'Invalid profile type.' }
    $entry = [AccountPanelCredentials+Entry]::new()
    $entry.Target=$value.target; $entry.UserName=$value.userName; $entry.Persist=[uint32]$value.persist
    $entry.Blob=[Convert]::FromBase64String($value.blob)
    return $entry
  } finally { [Array]::Clear($clear) }
}
function Load-Profile {
  if ($ProfileId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid profile identifier.' }
  $index=Get-Index
  $profile=@($index.profiles | Where-Object { $_.id -ceq $ProfileId })
  if ($profile.Count -ne 1) { throw 'This profile is missing. Refresh the panel.' }
  $entry=Unprotect-Entry ([IO.File]::ReadAllBytes((Join-Path $DataRoot ($ProfileId+'.bin'))))
  $identity=Get-Identity $entry
  if ($identity.email -cne $profile[0].email) { throw 'The profile could not be verified. Switching was cancelled.' }
  return @{entry=$entry; profile=$profile[0]}
}
function Find-App {
  if (-not $AppExe -or -not [IO.File]::Exists($AppExe) -or [IO.Path]::GetFileName($AppExe) -ne 'Antigravity.exe') { throw 'Antigravity App was not found.' }
  $roots=@(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" | Where-Object {
    $_.ExecutablePath -eq $AppExe -and $_.CommandLine -notmatch '(?:^|\s)--type='
  })
  # Sidecars can also run with Antigravity.exe as their Node runtime. They
  # have no --type flag, so require an actual application window as well.
  $visible=@(foreach($root in $roots){$candidate=Get-Process -Id $root.ProcessId -ErrorAction SilentlyContinue;if($candidate -and $candidate.MainWindowHandle -ne [IntPtr]::Zero){$candidate}else{if($candidate){$candidate.Dispose()}}})
  if ($visible.Count -ne 1) { foreach($candidate in $visible){$candidate.Dispose()};throw 'Expected one running Antigravity App window. Open the app and try again.' }
  return $visible[0]
}
function Set-Status([string]$State,[string]$Message) {
  Write-JsonAtomic (Join-Path $DataRoot 'switch-status.json') @{state=$State;message=$Message;updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();profileId=$ProfileId;workerPid=$PID;workerStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString();phase=$phase;errorType=$errorType;errorCode=$errorCode}
}

function New-DesktopStartInfo([string]$Executable) {
  $start = [Diagnostics.ProcessStartInfo]::new($Executable)
  $start.WorkingDirectory = [IO.Path]::GetDirectoryName($Executable)
  $start.UseShellExecute = $false
  # The sidecar runs on the same Antigravity executable in Node mode.
  # Launch the desktop app in the user's environment, without sidecar flags.
  foreach ($key in @($start.Environment.Keys)) {
    if ($key -match '^(ELECTRON_|NODE_OPTIONS$|NODE_PATH$|ANTIGRAVITY_(LS_ADDRESS$|CSRF_TOKEN$|EXECUTABLE_DATA_DIR$|SIDECAR_))') {
      $null = $start.Environment.Remove($key)
    }
  }
  return $start
}
function Start-Desktop([string]$Executable) {
  $process = [Diagnostics.Process]::Start((New-DesktopStartInfo $Executable))
  if ($null -eq $process) { throw 'Could not launch Antigravity.' }
  return $process
}
function Wait-DesktopWindow([Diagnostics.Process]$Process, [int]$TimeoutMilliseconds) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
    $Process.Refresh()
    if ($Process.HasExited) { return $false }
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
      # A visible window must survive the first moments of startup.
      if ($Process.WaitForExit(900)) { return $false }
      $Process.Refresh()
      if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $true }
    }
    Start-Sleep -Milliseconds 250
  }
  return $false
}

$lock=$null; $main=$null; $newMain=$null; $closed=$false; $rollback=$null; $credentialTouched=$false
$phase='begin';$errorType=$null;$errorCode=$null
try {
  switch ($Action) {
    'Current' {
      $identity=Get-Identity ([AccountPanelCredentials]::Read('gemini:antigravity'))
      @{ok=$true;current=$identity} | ConvertTo-Json -Compress
    }
    'Save' {
      $lock=Lock-Vault
      $entry=[AccountPanelCredentials]::Read('gemini:antigravity')
      $identity=Get-Identity $entry
      $index=Get-Index
      $existing=@($index.profiles | Where-Object { $_.email -ceq $identity.email })
      $id=if($existing.Count -eq 1){$existing[0].id}else{[guid]::NewGuid().ToString('N')}
      $encrypted=Protect-Entry $entry
      $temp=Join-Path $DataRoot ($id+'.bin.tmp')
      [IO.File]::WriteAllBytes($temp,$encrypted)
      $verified=Unprotect-Entry ([IO.File]::ReadAllBytes($temp))
      if (-not [Linq.Enumerable]::SequenceEqual[byte]($verified.Blob,$entry.Blob)) { throw 'The encrypted copy could not be verified.' }
      [IO.File]::Move($temp,(Join-Path $DataRoot ($id+'.bin')),$true)
      $profile=@{id=$id;email=$identity.email;name=$identity.name;label=([string]$Label).Trim();updatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()}
      if (-not $profile.label -and $existing.Count -eq 1) { $profile.label=$existing[0].label }
      $index.profiles=@($index.profiles | Where-Object { $_.id -cne $id })+@($profile)
      Write-JsonAtomic (Join-Path $DataRoot 'profiles.json') $index
      @{ok=$true;profile=$profile} | ConvertTo-Json -Depth 5 -Compress
    }
    'Plan' {
      $saved=Load-Profile
      $current=Get-Identity ([AccountPanelCredentials]::Read('gemini:antigravity'))
      $main=Find-App
      @{ok=$true;same=($current.email -ceq $saved.profile.email);pid=$main.Id;startTicks=$main.StartTime.ToUniversalTime().Ticks.ToString()} | ConvertTo-Json -Compress
    }
    'Launch' {
      $saved=Load-Profile
      $main=Find-App
      if ($main.Id -ne $ExpectedProcessId -or $main.StartTime.ToUniversalTime().Ticks.ToString() -cne $ExpectedStartTicks) { throw 'The app session changed. Switching was cancelled.' }
      # A dotnet-tool shim runs inside dotnet.exe; launch the real PowerShell
      # apphost so its arguments are not mistaken for dotnet CLI arguments.
      $workerExe=Join-Path $PSHOME 'pwsh.exe'
      if(-not [IO.File]::Exists($workerExe)){throw 'The PowerShell executable was not found.'}
      $workerArgs=@('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Action','Switch','-DataRoot',$DataRoot,'-ProfileId',$ProfileId,'-AppExe',$AppExe,'-ExpectedProcessId',[string]$ExpectedProcessId,'-ExpectedStartTicks',$ExpectedStartTicks)
      $workerId=[AccountPanelWorker]::Launch($workerExe,$workerArgs,[IO.Path]::GetDirectoryName($PSCommandPath))
      $worker=Get-Process -Id $workerId
      try { @{ok=$true;workerPid=$workerId;workerStartTicks=$worker.StartTime.ToUniversalTime().Ticks.ToString()} | ConvertTo-Json -Compress } finally {$worker.Dispose()}
    }
    'Switch' {
      $phase='lock-vault'
      $lock=Lock-Vault
      $phase='load-profile'
      $saved=Load-Profile
      $phase='find-app'
      $main=Find-App
      $phase='verify-generation'
      if ($main.Id -ne $ExpectedProcessId -or $main.StartTime.ToUniversalTime().Ticks.ToString() -cne $ExpectedStartTicks) { throw 'The app session changed. Switching was cancelled; choose the account again.' }
      $phase='read-current'
      $current=Get-Identity ([AccountPanelCredentials]::Read('gemini:antigravity'))
      if ($current.email -ceq $saved.profile.email) { Set-Status 'done' 'This account is already active.'; break }
      Set-Status 'closing' 'Closing Antigravity before switching…'
      # This one-shot worker deliberately survives its hosting sidecar. It never
      # force-closes the app, an IDE, other sessions or arbitrary named processes.
      Start-Sleep -Milliseconds 700
      if (-not $main.CloseMainWindow()) { throw 'Antigravity did not accept the close request. Sign-in data was not changed.' }
      if (-not $main.WaitForExit(20000)) { throw 'Antigravity is waiting to close or save. Finish your work and try again. Sign-in data was not changed.' }
      $closed=$true
      $phase='wait-shutdown'
      # Allow the native credential writer to finish; never race another root.
      $deadline=[DateTime]::UtcNow.AddSeconds(8)
      do {
        $remaining=@(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" | Where-Object { $_.ExecutablePath -eq $AppExe })
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 300
      } while ([DateTime]::UtcNow -lt $deadline)
      if ($remaining.Count -gt 0) { throw 'Antigravity processes are still running. The account was not changed.' }
      $phase='save-rollback'
      $rollback=[AccountPanelCredentials]::Read('gemini:antigravity')
      if ($null -eq $rollback) { throw 'The current sign-in disappeared during shutdown. Switching was cancelled.' }
      [IO.File]::WriteAllBytes((Join-Path $DataRoot 'last-rollback.bin'),(Protect-Entry $rollback))
      Set-Status 'restarting' 'Opening Antigravity with the selected account…'
      $phase='write-profile'
      $credentialTouched=$true
      [AccountPanelCredentials]::Write($saved.entry)
      $written=[AccountPanelCredentials]::Read('gemini:antigravity')
      if (-not [Linq.Enumerable]::SequenceEqual[byte]($written.Blob,$saved.entry.Blob)) { throw 'The saved sign-in could not be verified.' }
      $phase='launch-desktop'
      $newMain=Start-Desktop $AppExe
      if (-not (Wait-DesktopWindow $newMain 22000)) {
        if (-not $newMain.HasExited) { throw 'Antigravity is running, but no window appeared yet. Wait for it to open, then verify the profile.' }
        $newMain.Dispose()
        $newMain=$null
        $phase='retry-desktop'
        $newMain=Start-Desktop $AppExe
        if (-not (Wait-DesktopWindow $newMain 12000)) {
          throw 'Antigravity did not confirm that its window reopened.'
        }
      }
      $phase='verify-profile'
      $active=Get-Identity ([AccountPanelCredentials]::Read('gemini:antigravity'))
      if ($active.email -cne $saved.profile.email) { throw 'Antigravity reopened, but the selected profile could not be verified. Check your account in settings.' }
      $phase='complete'
      Set-Status 'done' 'Antigravity reopened with the selected account.'
    }
    'SelfTest' {
      $testRoot=Join-Path $DataRoot ('synthetic-'+[guid]::NewGuid().ToString('N'))
      $originalRoot=$DataRoot
      try {
        $DataRoot=$testRoot
        Initialize-PrivateDirectory
      } finally {
        $DataRoot=$originalRoot
        if([IO.Directory]::Exists($testRoot)){[IO.Directory]::Delete($testRoot,$false)}
      }
      $target='Codex.AccountPanel.SelfTest.'+[guid]::NewGuid().ToString('N')
      try {
        $sample=[AccountPanelCredentials+Entry]::new()
        $sample.Target=$target;$sample.UserName='synthetic';$sample.Persist=1;$sample.Blob=$utf8.GetBytes('synthetic-only')
        [AccountPanelCredentials]::Write($sample)
        $read=[AccountPanelCredentials]::Read($target)
        if (-not [Linq.Enumerable]::SequenceEqual[byte]($read.Blob,$sample.Blob)) {throw 'Credential roundtrip failed'}
        $sample.Target='gemini:antigravity'
        $protected=Protect-Entry $sample
        $restored=Unprotect-Entry $protected
        if (-not [Linq.Enumerable]::SequenceEqual[byte]($restored.Blob,$sample.Blob)) {throw 'DPAPI roundtrip failed'}
      } finally { [AccountPanelCredentials]::DeleteTest($target) }
      if ($null -ne [AccountPanelCredentials]::Read($target)) {throw 'Synthetic credential cleanup failed'}
      @{ok=$true;credentialRoundtrip=$true;encryptionRoundtrip=$true;syntheticCredentialRemoved=$true} | ConvertTo-Json -Compress
    }
  }
} catch {
  $failure=$_.Exception
  if($failure.InnerException){$failure=$failure.InnerException}
  $errorType=$failure.GetType().FullName;$errorCode=$failure.HResult
  $message=[string]$_.Exception.Message
  $safeMessages=@(
    'No Antigravity sign-in was found in Windows Credential Manager. Sign in to the app first.',
    'Could not identify the account email. Sign in through Google in Antigravity and try again.',
    'No reusable sign-in data was found. Sign in to Antigravity again.',
    'Could not read the profile index. No data was changed.',
    'The private profile directory permissions could not be verified. No data was changed.',
    'Another operation is running. Wait for it to finish.',
    'Invalid profile type.',
    'Invalid profile identifier.',
    'This profile is missing. Refresh the panel.',
    'The profile could not be verified. Switching was cancelled.',
    'Antigravity App was not found.',
    'Expected one running Antigravity App window. Open the app and try again.',
    'The encrypted copy could not be verified.',
    'The app session changed. Switching was cancelled.',
    'The PowerShell executable was not found.',
    'The app session changed. Switching was cancelled; choose the account again.',
    'This account is already active.',
    'Closing Antigravity before switching…',
    'Antigravity did not accept the close request. Sign-in data was not changed.',
    'Antigravity is waiting to close or save. Finish your work and try again. Sign-in data was not changed.',
    'Antigravity processes are still running. The account was not changed; the app will reopen.',
    'The current sign-in disappeared during shutdown. Switching was cancelled.',
    'Opening Antigravity with the selected account…',
    'The saved sign-in could not be verified.',
    'The app did not start.',
    'Could not launch Antigravity.',
    'Antigravity processes are still running. The account was not changed.',
    'Antigravity is running, but no window appeared yet. Wait for it to open, then verify the profile.',
    'Antigravity did not confirm that its window reopened.',
    'Antigravity reopened, but the selected profile could not be verified. Check your account in settings.',
    'Antigravity reopened with the selected account.',
    'The Windows secure-storage operation failed. Sign-in secrets were not sent to the panel.'
  )
  if ($message -cnotin $safeMessages) {
    $message='The Windows secure-storage operation failed. Sign-in secrets were not sent to the panel.'
  }
  if ($Action -eq 'Switch') {
    if ($closed -and ($null -eq $newMain -or $newMain.HasExited)) {
      # Never overwrite an identity that a live desktop process may be using.
      $otherRoot=@(Get-CimInstance Win32_Process -Filter "Name='Antigravity.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $AppExe -and $_.CommandLine -notmatch '(?:^|\s)--(?:type=|import\b)' })
      if ($otherRoot.Count -eq 0) {
        if ($credentialTouched -and $null -ne $rollback) {
          try {[AccountPanelCredentials]::Write($rollback);$message+=' The previous sign-in was restored.'}
          catch {$message+=' Could not restore the previous sign-in.'}
        }
        $reopened=$null
        try {
          $reopened=Start-Desktop $AppExe
          if (-not (Wait-DesktopWindow $reopened 12000)) { $message+=' Check whether the app reopened.' }
          else { $message+=' The app reopened.' }
        } catch { $message+=' Open Antigravity manually.' }
        finally { if ($null -ne $reopened) { $reopened.Dispose() } }
      }
    }
    try {Set-Status 'failed' $message} catch {}
  }
  @{ok=$false;error=$message} | ConvertTo-Json -Compress
  exit 1
} finally {
  if($null -ne $lock){$lock.Dispose()}
  if($null -ne $main){$main.Dispose()}
  if($null -ne $newMain){$newMain.Dispose()}
}
