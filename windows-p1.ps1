<# windows-onefile-npcap.ps1 — One-command Windows installer for mtr-logger (with Npcap + Scapy traceroute)
    - Python 3.13.3 (EXE first; no-visibility fallback to embeddable ZIP + pip bootstrap)
    - Npcap silent install (WinPcap-compatible)
    - venv + pip install -e .
    - Scapy traceroute shim (icmp|tcp|udp), replaces previous tracert.exe wrapper
    - Correct schtasks quoting via cmd.exe /d /c "<full command>"
    - Optional inbound ICMP firewall rule
    - PATH refresh for current session
#>

$ErrorActionPreference = 'Stop'

# ----------------- Defaults -----------------
$GIT_URL_DEFAULT      = "https://github.com/CalebBrendel/mtr-logger.git"
$BRANCH_DEFAULT       = "main"
$PREFIX_DEFAULT       = "C:\mtr-logger"
$BIN_DIR_DEFAULT      = "C:\mtr-logger\bin"

$TARGET_DEFAULT       = "google.ca"
$PROTO_DEFAULT        = "icmp"     # icmp|tcp|udp
$DNS_DEFAULT          = "auto"
$INTERVAL_DEFAULT     = "0.3"
$TIMEOUT_DEFAULT      = "0.3"
$PROBES_DEFAULT       = "3"
$ASCII_DEFAULT        = "yes"

$LOGS_PER_HOUR_DEFAULT= 4          # must divide 60
$SAFETY_MARGIN_DEFAULT= 5
$ARCHIVE_RETENTION_DEFAULT = 90

# Python downloads
$PY_VERSION = "3.13.3"
$PY_EXE_URL  = "https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-amd64.exe"
$PY_ZIP_URL  = "https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-embed-amd64.zip"
$GET_PIP_URL = "https://bootstrap.pypa.io/get-pip.py"

# Npcap (adjust if you want to pin a different version)
$NPCAP_URL = "https://nmap.org/npcap/dist/npcap-1.79.exe"

# Derived (updated after prompts)
$SRC_DIR   = Join-Path $PREFIX_DEFAULT "src"
$VENV_DIR  = Join-Path $PREFIX_DEFAULT ".venv"
$EMB_DIR   = Join-Path $PREFIX_DEFAULT "pyembed"
$WRAPPER_PS= Join-Path $BIN_DIR_DEFAULT "mtr-logger.ps1"
$WRAPPER_CMD=Join-Path $BIN_DIR_DEFAULT "mtr-logger.cmd"
$UNINSTALL_PS = Join-Path $BIN_DIR_DEFAULT "uninstall.ps1"
$LOG_DIR  = Join-Path $env:USERPROFILE "mtr\logs"
$MAIN_TASK = "mtr-logger\Log"
$ARCH_TASK = "mtr-logger\Archive"

# ----------------- Helpers -----------------
function Require-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}
function Ensure-TLS12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {} }
function Ensure-Dir($p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
function Read-Default([string]$Prompt, [string]$Default) { $v = Read-Host "$Prompt [$Default]"; if ([string]::IsNullOrWhiteSpace($v)) { $Default } else { $v.Trim() } }
function Validate-FactorOf60([int]$n) { return ($n -in 1,2,3,4,5,6,10,12,15,20,30,60) }
function Minute-Marks([int]$perHour) { $step=[int](60/$perHour); ($((0..59 | Where-Object {$_%$step -eq 0})) -join ",") }
function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path','User')
  if     ($machine -and $user) { $env:Path = ($machine.TrimEnd(';') + ';' + $user) }
  elseif ($machine)            { $env:Path = $machine }
  elseif ($user)               { $env:Path = $user }
  else                         { $env:Path = "" }
}
function Remove-StorePythonStubs {
  $wa = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
  foreach($s in @("python.exe","python3.exe","python3.11.exe","python3.12.exe","python3.13.exe")){
    $p = Join-Path $wa $s; if (Test-Path $p) { try { Remove-Item -Force $p } catch {} }
  }
}
function Resolve-Python {
  try { Get-Command py -ErrorAction Stop | Out-Null; $p = & py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null; if ($p -and (Test-Path $p.Trim())) { return $p.Trim() } } catch {}
  foreach($root in @("HKLM:\SOFTWARE\Python\PythonCore","HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore","HKCU:\SOFTWARE\Python\PythonCore")){
    try { if(Test-Path $root){ Get-ChildItem $root -ErrorAction Stop | ForEach-Object {
      $ip = Join-Path $_.PSPath "InstallPath"
      if(Test-Path $ip){
        $path = (Get-ItemProperty -Path $ip -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
        if($path){ $exe = Join-Path $path "python.exe"; if(Test-Path $exe){ return $exe } }
      } } } } catch {}
  }
  foreach ($c in @(
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPROGRAMPATH\Python311\python.exe"
  )) { if (Test-Path $c) { return $c } }
  try { $pc=Get-Command python -ErrorAction Stop; if($pc.Source -and (Test-Path $pc.Source)){ return $pc.Source } } catch {}
  return $null
}
function Check-PyVersion([string]$PyExe, [version]$MinVersion = [version]"3.8") {
  $v = & $PyExe -c "import sys;print('.'.join(map(str,sys.version_info[:3])))"
  $v = ($v | Select-Object -First 1).Trim()
  if (-not ($v -match '^\d+\.\d+(\.\d+)?$')) { throw "Could not parse Python version string: '$v'" }
  if ([version]$v -lt $MinVersion) { throw "Python $v is below required minimum $MinVersion" }
  return $true
}

# ----------------- Chocolatey + deps -----------------
function Ensure-Choco {
  if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ALLUSERSPROFILE\chocolatey\bin"
  }
}
function Ensure-GitCurl {
  choco install -y --no-progress git | Out-Null
  choco install -y --no-progress curl | Out-Null
  Refresh-Path
}

# --- Install Python via EXE; fallback to embeddable ZIP ---
function Install-Python-EXE {
  Remove-StorePythonStubs; Refresh-Path
  $tmp = Join-Path $env:TEMP ("python-"+$PY_VERSION+"-"+[guid]::NewGuid().ToString()+".exe")
  $log = Join-Path $env:TEMP ("PythonInstall-"+(Get-Date -Format "yyyyMMdd-HHmmss")+".log")
  Write-Host "Downloading Python $PY_VERSION (EXE) ..."
  Invoke-WebRequest -UseBasicParsing -Uri $PY_EXE_URL -OutFile $tmp

  Write-Host "Installing Python (All-Users, silent)..."
  $argsAU = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1 InstallLauncherAllUsers=1 /log `"$log`""
  Start-Process $tmp -ArgumentList $argsAU -Wait
  Refresh-Path; Start-Sleep -Seconds 2
  $py = Resolve-Python
  if ($py) { try { Remove-Item $tmp -Force } catch {}; return @{ Path=$py; Log=$log } }

  Write-Host "All-Users install not visible; retrying Per-User install..."
  $argsPU = "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_launcher=1 /log `"$log`""
  Start-Process $tmp -ArgumentList $argsPU -Wait
  Refresh-Path; Start-Sleep -Seconds 2
  $py = Resolve-Python
  try { Remove-Item $tmp -Force } catch {}
  return @{ Path=$py; Log=$log }
}
function Install-Python-Embeddable {
  if (Test-Path $EMB_DIR) { try { Remove-Item -Recurse -Force $EMB_DIR } catch {} }
  Ensure-Dir $EMB_DIR
  $zip   = Join-Path $env:TEMP ("python-embed-"+$PY_VERSION+"-"+[guid]::NewGuid().ToString()+".zip")
  Write-Host "Downloading Python $PY_VERSION (embeddable ZIP)..."
  Invoke-WebRequest -UseBasicParsing -Uri $PY_ZIP_URL -OutFile $zip
  Write-Host "Unpacking embeddable..."
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $EMB_DIR)
  try { Remove-Item $zip -Force } catch {}
  $pth = Get-ChildItem -Path $EMB_DIR -Filter "python*.pth" -File | Select-Object -First 1
  if ($pth) { (Get-Content $pth) -replace '^\s*#\s*import site\s*$', 'import site' | Set-Content -Encoding ASCII $pth }
  $getpip = Join-Path $env:TEMP ("get-pip-"+[guid]::NewGuid().ToString()+".py")
  Invoke-WebRequest -UseBasicParsing -Uri $GET_PIP_URL -OutFile $getpip
  $pyexe = Join-Path $EMB_DIR "python.exe"
  & $pyexe $getpip --no-warn-script-location
  try { Remove-Item $getpip -Force } catch {}
  & $pyexe -m pip install -U pip wheel --no-warn-script-location | Out-Null
  return $pyexe
}
function Ensure-Embeddable-Pip([string]$PyExe) {
  $root = Split-Path -Parent $PyExe
  $pth = Get-ChildItem -Path $root -Filter "python*.pth" -File | Select-Object -First 1
  if ($pth) {
    $content = Get-Content $pth
    $new = $content -replace '^\s*#\s*import site\s*$', 'import site'
    if ($new -ne $content) { Set-Content -Path $pth -Value $new -Encoding ASCII }
  }
  try { & $PyExe -m pip --version 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch {}
  $getpip = Join-Path $env:TEMP ("get-pip-"+[guid]::NewGuid().ToString()+".py")
  Invoke-WebRequest -UseBasicParsing -Uri $GET_PIP_URL -OutFile $getpip
  & $PyExe $getpip --no-warn-script-location
  try { Remove-Item $getpip -Force } catch {}
}

# --------- Scheduled Task helpers ---------
function Task-Exists([string]$Name) { cmd /c "schtasks /Query /TN `"$Name`" >NUL 2>&1"; return ($LASTEXITCODE -eq 0) }
function Task-Delete-IfExists([string]$Name) { if (Task-Exists $Name) { cmd /c "schtasks /Delete /TN `"$Name`" /F >NUL 2>&1" } }
function Task-Create([string]$Name, [string]$CmdLine, [string]$Schedule, [string]$Mo = "", [string]$StartTime = "") {
  $Wrapped = "cmd.exe /d /c " + $CmdLine
  $WrappedQuoted = '"' + $Wrapped + '"'
  $args = @("/Create","/TN",$Name,"/TR",$WrappedQuoted,"/RU","SYSTEM","/RL","HIGHEST","/F","/SC",$Schedule)
  if ($Mo)       { $args += @("/MO",$Mo) }
  if ($StartTime){ $args += @("/ST",$StartTime) }
  Start-Process -FilePath schtasks.exe -ArgumentList $args -NoNewWindow -Wait
}

# ----------------- Main -----------------
Require-Admin
Ensure-TLS12

Write-Host @"
         __           .__
  ______/  |________  |  |   ____   ____   ____   ___________
 /     \   __\_  __ \ |  |  /  _ \ / ___\ / ___\_/ __ \_  __ \
|  Y Y  \  |  |  | \/ |  |_(  <_> ) /_/  > /_/  >  ___/|  | \/
|__|_|  /__|  |__|    |____/\____/\___  /\___  / \___  >__|
      \/                         /_____//_____/      \/
== mtr-logger bootstrap (Windows + Npcap) ==
"@

# 1) Tools
Write-Host "[1/12] Ensuring Chocolatey..."
Ensure-Choco
Write-Host "[2/12] Installing Git + curl (Chocolatey)..."
Ensure-GitCurl

# 2) Python
Write-Host "[3/12] Installing Python..."
$exeRes = Install-Python-EXE
$PYEXE = $null
if ($exeRes.Path) {
  $PYEXE = $exeRes.Path
  Write-Host ("    - Python (EXE): {0}" -f $PYEXE)
} else {
  Write-Host "    - EXE install not visible; falling back to embeddable ZIP…"
  if ($exeRes.Log -and (Test-Path $exeRes.Log)) {
    Write-Host "    (Installer log tail):"
    try { Get-Content -Path $exeRes.Log -Tail 40 | ForEach-Object { Write-Host "      $_" } } catch {}
  }
  $PYEXE = Install-Python-Embeddable
  Write-Host ("    - Python (embeddable): {0}" -f $PYEXE)
}
Check-PyVersion -PyExe $PYEXE | Out-Null

# 3) Npcap
Write-Host "[4/12] Installing Npcap (WinPcap-compatible)..."
$tmpNpcap = Join-Path $env:TEMP ("npcap-"+[guid]::NewGuid().ToString()+".exe")
Invoke-WebRequest -UseBasicParsing -Uri $NPCAP_URL -OutFile $tmpNpcap
# /S silent, /winpcap_mode for WinPcap API, /admin_only=1 limits to Admins (safer)
$npcArgs = "/S /winpcap_mode=yes /admin_only=yes"
Start-Process -FilePath $tmpNpcap -ArgumentList $npcArgs -Wait
try { Remove-Item $tmpNpcap -Force } catch {}
Start-Sleep -Seconds 2

# 4) Prompts
Write-Host "[5/12] Prompting for settings..."
$GIT_URL  = Read-Default "Git URL"              $GIT_URL_DEFAULT
if ($GIT_URL -notmatch '^https://|^git@') { Write-Host "WARNING: invalid URL; using default."; $GIT_URL = $GIT_URL_DEFAULT }
$BRANCH   = Read-Default "Branch"               $BRANCH_DEFAULT
$PREFIX   = Read-Default "Install prefix"       $PREFIX_DEFAULT
$BIN_DIR  = Read-Default "Wrapper dir to add to PATH" $BIN_DIR_DEFAULT

$TARGET   = Read-Default "Target (hostname/IP)" $TARGET_DEFAULT
$PROTO    = Read-Default "Probe protocol (icmp|tcp|udp)" $PROTO_DEFAULT
$DNS_MODE = Read-Default "DNS mode (auto|on|off)" $DNS_DEFAULT
$INTERVAL = Read-Default "Interval seconds (-i)" $INTERVAL_DEFAULT
$TIMEOUT  = Read-Default "Timeout seconds (--timeout)" $TIMEOUT_DEFAULT
$PROBES   = Read-Default "Probes per hop (-p)" $PROBES_DEFAULT
$ASCII    = Read-Default "Use ASCII borders? (yes/no)" $ASCII_DEFAULT

$LPH      = [int](Read-Default "How many logs per hour (must divide 60 evenly)" "$LOGS_PER_HOUR_DEFAULT")
if (-not (Validate-FactorOf60 $LPH)) { Write-Host "ERROR: $LPH does not evenly divide 60." -ForegroundColor Red; exit 2 }
$SAFETY   = [int](Read-Default "Safety margin seconds (subtract from each window)" "$SAFETY_MARGIN_DEFAULT")

$SRC_DIR  = Join-Path $PREFIX "src"
$VENV_DIR = Join-Path $PREFIX ".venv"
$EMB_DIR  = Join-Path $PREFIX "pyembed"
$WRAPPER_PS = Join-Path $BIN_DIR "mtr-logger.ps1"
$WRAPPER_CMD= Join-Path $BIN_DIR "mtr-logger.cmd"
$UNINSTALL_PS = Join-Path $BIN_DIR "uninstall.ps1"

$stepMin = [int](60 / $LPH)
$windowSec = $stepMin * 60
$duration = $windowSec - $SAFETY
if ($duration -le 0) { Write-Host "ERROR: Safety too large for frequency." -ForegroundColor Red; exit 2 }
$minuteMarks = Minute-Marks $LPH

Write-Host ""
Write-Host ("Schedule (TZ={0})" -f (tzutil /g 2>$null))
Write-Host ("  Minute marks: {0}" -f $minuteMarks)
Write-Host ("  Window seconds: {0}" -f $windowSec)
Write-Host ("  Duration seconds: {0}" -f $duration)
Write-Host ""

# 5) Repo + venv
Write-Host "[6/12] Preparing install root + cloning repo..."
Ensure-Dir $PREFIX
if (Test-Path (Join-Path $SRC_DIR ".git")) {
  git -C $SRC_DIR remote set-url origin $GIT_URL | Out-Null
  git -C $SRC_DIR fetch origin --depth=1 | Out-Null
  git -C $SRC_DIR checkout -q $BRANCH
  git -C $SRC_DIR reset --hard "origin/$BRANCH" | Out-Null
} else {
  if (Test-Path $SRC_DIR) { Remove-Item -Recurse -Force $SRC_DIR }
  git clone --depth=1 --branch $BRANCH $GIT_URL $SRC_DIR | Out-Null
}
if (-not (Test-Path (Join-Path $SRC_DIR "pyproject.toml"))) {
  Write-Host "pyproject.toml not found in $SRC_DIR" -ForegroundColor Red; exit 1
}

Write-Host "[7/12] Creating virtualenv + installing package..."
& $PYEXE -m venv $VENV_DIR
$RUN_PY  = Join-Path $VENV_DIR "Scripts\python.exe"
& $RUN_PY -m pip install -U pip wheel | Out-Null
& $RUN_PY -m pip install -e $SRC_DIR | Out-Null
# scapy for raw traceroute
& $RUN_PY -m pip install scapy | Out-Null

# 6) Wrappers + uninstall
Write-Host "[8/12] Creating wrapper, traceroute shim, and uninstall in $BIN_DIR"
Ensure-Dir $BIN_DIR

# Uninstall
@"
param()
Write-Host "This will uninstall mtr-logger:" -ForegroundColor Yellow
Write-Host "  PREFIX:  $PREFIX"
Write-Host "  PY:      $RUN_PY"
Write-Host "  WRAPPER: $WRAPPER_CMD / $WRAPPER_PS"
`$ans = Read-Host "Proceed with uninstall? [y/N]"
if (!(`$ans) -or `$ans.ToLower() -notin @('y','yes')) { Write-Host "Aborted."; exit 0 }

Write-Host "[1/6] Removing Scheduled Tasks..."
cmd /c "schtasks /Delete /TN `"$MAIN_TASK`" /F >NUL 2>&1"
cmd /c "schtasks /Delete /TN `"$ARCH_TASK`" /F >NUL 2>&1"

Write-Host "[2/6] Removing install dir..."
if (Test-Path "$PREFIX") { Remove-Item -Recurse -Force "$PREFIX" }

Write-Host "[3/6] Removing wrappers..."
if (Test-Path "$WRAPPER_CMD") { Remove-Item -Force "$WRAPPER_CMD" }
if (Test-Path "$WRAPPER_PS")  { Remove-Item -Force "$WRAPPER_PS" }
if (Test-Path (Join-Path "$BIN_DIR" "traceroute.py"))  { Remove-Item -Force (Join-Path "$BIN_DIR" "traceroute.py") }

Write-Host "[4/6] (Optional) Remove logs at `$env:USERPROFILE\mtr\logs"
`$del = Read-Host "Delete logs as well? [y/N]"
if (`$del -and `$del.ToLower() -in @('y','yes')) {
  `$logdir = Join-Path `$env:USERPROFILE 'mtr\logs'
  if (Test-Path `$logdir) { Remove-Item -Recurse -Force `$logdir }
}

Write-Host "[5/6] Removing ICMP firewall rule (if present)..."
Get-NetFirewallRule -DisplayName "Allow ICMPv4 for traceroute" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

Write-Host "[6/6] Uninstall complete."
"@ | Set-Content -Encoding UTF8 $UNINSTALL_PS

# Wrapper (PS)
@"
param([Parameter(ValueFromRemainingArguments=`$true)]`$Args)
if (`$Args.Count -gt 0 -and `$Args[0].ToString().ToLower() -eq 'uninstall') {
  & "$UNINSTALL_PS"
  exit `$LASTEXITCODE
}
& "$RUN_PY" -m mtrpy @Args
"@ | Set-Content -Encoding UTF8 $WRAPPER_PS

# Wrapper (CMD shim)
@"
@echo off
if /I "%~1"=="uninstall" (
  powershell -ExecutionPolicy Bypass -File "$UNINSTALL_PS"
  exit /b %ERRORLEVEL%
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "& `"$WRAPPER_PS`" %*"
"@ | Set-Content -Encoding OEM $WRAPPER_CMD

# --- Scapy-based traceroute shim (supports icmp|tcp|udp) ---
$trPy = @'
import os, sys, time, socket
from scapy.all import IP, ICMP, UDP, TCP, sr1, conf

def main(argv):
    # Very small arg surface we need: -n (ignore), -m (maxhops), -w (timeout), --proto (custom)
    dest = None
    maxhops = 30
    timeout = 1.0
    proto = "icmp"
    dport = 33434  # UDP default
    tport = 80     # TCP default

    it = iter(argv)
    for a in it:
        if a == "-n":
            pass
        elif a == "-m":
            try: maxhops = int(next(it))
            except StopIteration: pass
        elif a == "-w":
            try: timeout = float(next(it))
            except StopIteration: pass
        elif a == "--proto":
            try: proto = next(it)
            except StopIteration: pass
        elif a == "--dport":
            try: dport = int(next(it))
            except StopIteration: pass
        elif a == "--tport":
            try: tport = int(next(it))
            except StopIteration: pass
        elif a.startswith("-"):
            continue
        else:
            dest = a

    if not dest:
        print("Usage: traceroute <host> [--proto icmp|udp|tcp]", file=sys.stderr)
        return 2

    try:
        dst_ip = socket.gethostbyname(dest)
    except socket.gaierror:
        print(f"Cannot resolve {dest}", file=sys.stderr)
        return 1

    conf.verb = 0
    print(f"traceroute to {dest} ({dst_ip}), proto={proto}")

    for ttl in range(1, maxhops+1):
        pkt = IP(dst=dst_ip, ttl=ttl)
        if proto == "udp":
            layer = UDP(dport=dport)
        elif proto == "tcp":
            layer = TCP(dport=tport, flags="S")
        else:
            layer = ICMP()

        t0 = time.time()
        ans = sr1(pkt/layer, timeout=timeout)
        dt = int((time.time()-t0)*1000)

        if ans is None:
            print(f"{ttl:2d}  *  *  *")
            continue

        hop_ip = ans.src
        # Destination reached?
        reached = (proto == "icmp" and ans.haslayer(ICMP) and ans.getlayer(ICMP).type==0) or \
                  (proto == "udp"  and ans.haslayer(ICMP) and ans.getlayer(ICMP).type==3) or \
                  (proto == "tcp"  and ans.haslayer(TCP)  and ans.getlayer(TCP).flags & 0x12) # SYN-ACK
        print(f"{ttl:2d}  {hop_ip}  {dt} ms")
        if reached:
            break

    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
'@
Set-Content -Encoding UTF8 (Join-Path $BIN_DIR "traceroute.py") $trPy

# 7) PATH + optional firewall
Write-Host "[9/12] Ensuring $BIN_DIR on system PATH..."
$curPath = [Environment]::GetEnvironmentVariable("Path","Machine")
if (-not ($curPath -split ';' | Where-Object { $_ -ieq $BIN_DIR })) {
  [Environment]::SetEnvironmentVariable("Path", ($curPath.TrimEnd(';') + ";" + $BIN_DIR), "Machine")
  Write-Host "    - Added to system PATH (Machine)."
}

Write-Host "[10/12] Optional: allow ICMPv4 inbound for traceroute hops"
$addICMP = Read-Default "Add firewall rule for ICMPv4 types 0,3,11? (y/N)" "N"
if ($addICMP.ToUpper() -eq "Y") {
  try {
    New-NetFirewallRule -DisplayName "Allow ICMPv4 for traceroute" `
      -Direction Inbound -Protocol ICMPv4 -IcmpType 0,3,11 -Action Allow -Profile Any | Out-Null
    Write-Host "    - Rule added."
  } catch { Write-Host "    - Could not add firewall rule (continuing)." -ForegroundColor Yellow }
}

# 8) Scheduled Tasks
Write-Host "[11/12] Creating Scheduled Tasks..."
Ensure-Dir $LOG_DIR
$logOut = Join-Path $env:USERPROFILE "mtr-logger.log"
$archOut= Join-Path $env:USERPROFILE "mtr-logger-archive.log"

Task-Delete-IfExists $MAIN_TASK
Task-Delete-IfExists $ARCH_TASK

$logInner = """$WRAPPER_CMD"" ""$TARGET"" --proto ""$PROTO"" --dns ""$DNS_MODE"" -i ""$INTERVAL"" --timeout ""$TIMEOUT"" -p ""$PROBES"" --duration $duration --export --outfile auto >> ""$logOut"" 2>&1"
Task-Create -Name $MAIN_TASK -CmdLine $logInner -Schedule "MINUTE" -Mo "$stepMin"

$archInner = """$RUN_PY"" -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> ""$archOut"" 2>&1"
Task-Create -Name $ARCH_TASK -CmdLine $archInner -Schedule "DAILY" -StartTime "00:00"

# 9) PATH refresh + Self-test
Write-Host "[12/12] PATH refresh and self-test..."
Refresh-Path
if (($env:Path -split ';') -notcontains $BIN_DIR) { $env:Path = "$BIN_DIR;$env:Path" }

try {
  & "$WRAPPER_PS" $TARGET --proto $PROTO --dns $DNS_MODE -i $INTERVAL --timeout $TIMEOUT -p $PROBES --duration 3 --export --outfile auto | Out-Null
  Write-Host "    - Self-test invoked."
} catch {
  Write-Host "    - Self-test not conclusive (ok to ignore)."
}

Write-Host ""
Write-Host "✅ Install complete."
Write-Host "Try interactive NOW (no new terminal needed):"
Write-Host "  mtr-logger $TARGET --proto $PROTO"
Write-Host "Or try TCP if ICMP seems filtered:"
Write-Host "  mtr-logger $TARGET --proto tcp"
Write-Host "Uninstall anytime:  mtr-logger uninstall"
Write-Host "Logs: $LOG_DIR"
