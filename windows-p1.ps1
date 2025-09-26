<#  windows-onefile.ps1 — One-command Windows installer for mtr-logger (PowerShell 5.1+)
    v6.6:
      - Adds traceroute shim (traceroute.ps1/.cmd -> tracert.exe)
      - Robust embeddable pip bootstrap (always enable 'import site'; no Start-Process redirect clash)
      - Refreshes PATH for the **current session** so `mtr-logger` works immediately
      - EXE-first Python install; fallback to embeddable ZIP
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
  if ($machine -and $user)      { $env:Path = ($machine.TrimEnd(';') + ';' + $user) }
  elseif ($machine)             { $env:Path = $machine }
  elseif ($user)                { $env:Path = $user }
  else                          { $env:Path = "" }
}
function Remove-StorePythonStubs {
  $wa = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
  foreach($s in @("python.exe","python3.exe","python3.11.exe","python3.12.exe","python3.13.exe")){
    $p = Join-Path $wa $s; if (Test-Path $p) { try { Remove-Item -Force $p } catch {} }
  }
}

# --- Python resolvers ---
function Resolve-Python-FromRegistry {
  $roots = @(
    "HKLM:\SOFTWARE\Python\PythonCore",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore",
    "HKCU:\SOFTWARE\Python\PythonCore"
  )
  $cands = @()
  foreach($root in $roots){
    try {
      if(Test-Path $root){
        Get-ChildItem $root -ErrorAction Stop | ForEach-Object {
          $ip = Join-Path $_.PSPath "InstallPath"
          if(Test-Path $ip){
            $path = (Get-ItemProperty -Path $ip -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
            if($path){
              $exe = Join-Path $path "python.exe"
              if(Test-Path $exe){ $cands += $exe }
            }
          }
        }
      }
    } catch {}
  }
  $cands | Sort-Object -Descending -Unique | Select-Object -First 1
}
function Resolve-Python {
  try {
    Get-Command py -ErrorAction Stop | Out-Null
    $p = & py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null
    if ($p) { $p=$p.Trim(); if (Test-Path $p) { return $p } }
  } catch {}
  $reg = Resolve-Python-FromRegistry
  if($reg){ return $reg }
  $cands=@(
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPDATA\Programs\Python\Python311\python.exe","$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  foreach($root in @("C:\Program Files","C:\Program Files (x86)")){
    try {
      if(Test-Path $root){
        $hit = Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue -Filter python.exe -File | Select-Object -First 1
        if($hit){ return $hit.FullName }
      }
    } catch {}
  }
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
  choco install -y --no-progress git
  choco install -y --no-progress curl
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
  $existing = Join-Path $EMB_DIR "python.exe"
  if (Test-Path $existing) {
    Write-Host "Embeddable Python already present at $existing — reusing."
    return $existing
  }
  if (Test-Path $EMB_DIR) { try { Remove-Item -Recurse -Force $EMB_DIR } catch {} }
  Ensure-Dir $EMB_DIR

  $zip   = Join-Path $env:TEMP ("python-embed-"+$PY_VERSION+"-"+[guid]::NewGuid().ToString()+".zip")
  Write-Host "Downloading Python $PY_VERSION (embeddable ZIP)..."
  Invoke-WebRequest -UseBasicParsing -Uri $PY_ZIP_URL -OutFile $zip
  Write-Host "Unpacking embeddable..."
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $EMB_DIR)
  try { Remove-Item $zip -Force } catch {}

  # Enable site
  $pth = Get-ChildItem -Path $EMB_DIR -Filter "python*.pth" -File | Select-Object -First 1
  if ($pth) {
    $content = Get-Content $pth
    $content = $content -replace '^\s*#\s*import site\s*$', 'import site'
    Set-Content -Path $pth -Value $content -Encoding ASCII
  }

  # Bootstrap pip (no Start-Process; let errors surface)
  Write-Host "Bootstrapping pip inside embeddable..."
  $getpip = Join-Path $env:TEMP ("get-pip-"+[guid]::NewGuid().ToString()+".py")
  Invoke-WebRequest -UseBasicParsing -Uri $GET_PIP_URL -OutFile $getpip
  $pyexe = Join-Path $EMB_DIR "python.exe"
  & $pyexe $getpip --no-warn-script-location
  try { Remove-Item $getpip -Force } catch {}

  # Verify pip actually installed
  & $pyexe -m pip --version
  if ($LASTEXITCODE -ne 0) { throw "pip did not install correctly in embeddable runtime." }

  # Quietly ensure wheel
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
  try {
    & $PyExe -m pip --version 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
  } catch {}
  Write-Host "pip not found in embeddable — installing now..."
  $getpip = Join-Path $env:TEMP ("get-pip-"+[guid]::NewGuid().ToString()+".py")
  $pipLog = Join-Path $env:TEMP ("getpip-repair-"+(Get-Date -Format "yyyyMMdd-HHmmss")+".log")
  Invoke-WebRequest -UseBasicParsing -Uri $GET_PIP_URL -OutFile $getpip
  & $PyExe $getpip --no-warn-script-location *> $pipLog
  try { Remove-Item $getpip -Force } catch {}
  & $PyExe -m pip --version 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "get-pip repair log (tail):" -ForegroundColor Yellow
    try { Get-Content -Path $pipLog -Tail 80 | ForEach-Object { Write-Host "  $_" } } catch {}
    throw "pip still missing in embeddable runtime."
  }
}

# --------- Scheduled Task helpers (safe/quiet) ---------
function Task-Exists([string]$Name) {
  cmd /c "schtasks /Query /TN `"$Name`" >NUL 2>&1"
  return ($LASTEXITCODE -eq 0)
}
function Task-Delete-IfExists([string]$Name) {
  if (Task-Exists $Name) {
    cmd /c "schtasks /Delete /TN `"$Name`" /F >NUL 2>&1"
  }
}
function Task-Create([string]$Name, [string]$Cmd, [string]$Schedule, [string]$Mo = "", [string]$StartTime = "") {
  $common = @("/TN", $Name, "/TR", $Cmd, "/RU", "SYSTEM", "/RL", "HIGHEST", "/F")
  $args = @("/Create") + $common + @("/SC", $Schedule)
  if ($Mo)       { $args += @("/MO", $Mo) }
  if ($StartTime){ $args += @("/ST", $StartTime) }
  Start-Process -FilePath schtasks.exe -ArgumentList $args -NoNewWindow -Wait
}

# ----------------- Main flow -----------------
Require-Admin
Ensure-TLS12

Write-Host @"
         __           .__
  ______/  |________  |  |   ____   ____   ____   ___________
 /     \   __\_  __ \ |  |  /  _ \ / ___\ / ___\_/ __ \_  __ \
|  Y Y  \  |  |  | \/ |  |_(  <_> ) /_/  > /_/  >  ___/|  | \/
|__|_|  /__|  |__|    |____/\____/\___  /\___  / \___  >__|
      \/                         /_____//_____/      \/
== mtr-logger bootstrap (Windows, one-file) ==
"@

Write-Host "[1/12] Ensuring Chocolatey..."
Ensure-Choco

Write-Host "[2/12] Installing Git + curl (Chocolatey)..."
Ensure-GitCurl

Write-Host "[3/12] Installing Python..."
$exeRes = Install-Python-EXE
$PYEXE = $null
if ($exeRes.Path) {
  $PYEXE = $exeRes.Path
  Write-Host ("    - Python (EXE): {0}" -f $PYEXE)
} else {
  Write-Host "    - EXE install not available (policy or visibility). Falling back to embeddable ZIP…"
  if ($exeRes.Log -and (Test-Path $exeRes.Log)) {
    Write-Host "    (Installer log tail for reference):"
    try { Get-Content -Path $exeRes.Log -Tail 40 | ForEach-Object { Write-Host "      $_" } } catch {}
  }
  $PYEXE = Install-Python-Embeddable
  Write-Host ("    - Python (embeddable): {0}" -f $PYEXE)
}
Check-PyVersion -PyExe $PYEXE | Out-Null

Write-Host "[4/12] Prompting for settings..."
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

Write-Host "[5/12] Preparing install root: $PREFIX"
Ensure-Dir $PREFIX

Write-Host "[6/12] Cloning/updating repo..."
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

# Interpreter selection
$UsingEmbeddable = ($PYEXE -like "*\pyembed\*")
if ($UsingEmbeddable) {
  Write-Host "[7/12] Using embeddable Python at $PYEXE (no venv)"
  Ensure-Embeddable-Pip -PyExe $PYEXE
  $RUN_PY = $PYEXE
  Write-Host "[8/12] Installing package (editable) into embeddable runtime..."
  & $RUN_PY -m pip install -U pip wheel | Out-Null
  & $RUN_PY -m pip install -e $SRC_DIR | Out-Null
} else {
  Write-Host "[7/12] Creating virtualenv: $VENV_DIR"
  Ensure-Dir $VENV_DIR
  & $PYEXE -m venv $VENV_DIR
  $RUN_PY  = Join-Path $VENV_DIR "Scripts\python.exe"
  Write-Host "[8/12] Installing package (editable) into venv..."
  & $RUN_PY -m pip install -U pip wheel | Out-Null
  & $RUN_PY -m pip install -e $SRC_DIR | Out-Null
}

Write-Host "[9/12] Creating wrapper, traceroute shim, and uninstall in $BIN_DIR"
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

Write-Host "[1/5] Removing Scheduled Tasks..."
cmd /c "schtasks /Delete /TN `"$MAIN_TASK`" /F >NUL 2>&1"
cmd /c "schtasks /Delete /TN `"$ARCH_TASK`" /F >NUL 2>&1"

Write-Host "[2/5] Removing install dir..."
if (Test-Path "$PREFIX") { Remove-Item -Recurse -Force "$PREFIX" }

Write-Host "[3/5] Removing wrappers..."
if (Test-Path "$WRAPPER_CMD") { Remove-Item -Force "$WRAPPER_CMD" }
if (Test-Path "$WRAPPER_PS")  { Remove-Item -Force "$WRAPPER_PS" }
if (Test-Path (Join-Path "$BIN_DIR" "traceroute.cmd")) { Remove-Item -Force (Join-Path "$BIN_DIR" "traceroute.cmd") }
if (Test-Path (Join-Path "$BIN_DIR" "traceroute.ps1")) { Remove-Item -Force (Join-Path "$BIN_DIR" "traceroute.ps1") }

Write-Host "[4/5] (Optional) Remove logs at `$env:USERPROFILE\mtr\logs"
`$del = Read-Host "Delete logs as well? [y/N]"
if (`$del -and `$del.ToLower() -in @('y','yes')) {
  `$logdir = Join-Path `$env:USERPROFILE 'mtr\logs'
  if (Test-Path `$logdir) { Remove-Item -Recurse -Force `$logdir }
}

Write-Host "[5/5] Uninstall complete."
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

# --- traceroute shim (so tools expecting `traceroute` work on Windows) ---
@'
param([string[]]$Args)

$dest     = $null
$numeric  = $false    # -n -> tracert -d
$maxhops  = $null     # -m X -> tracert -h X
$timeoutS = $null     # -w S (seconds) -> tracert -w ms

for ($i=0; $i -lt $Args.Count; $i++) {
  $a = $Args[$i]
  switch ($a) {
    '-n' { $numeric = $true }
    '-m' { if ($i + 1 -lt $Args.Count) { $maxhops = [int]$Args[++$i] } }
    '-w' { if ($i + 1 -lt $Args.Count) { $timeoutS = [double]$Args[++$i] } }
    default {
      if ($a -notmatch '^-') { $dest = $a }
    }
  }
}

if (-not $dest) { Write-Error "Usage: traceroute <host>"; exit 1 }

$trArgs = @()
if ($numeric)    { $trArgs += '-d' }
if ($maxhops)    { $trArgs += @('-h', [int]$maxhops) }
if ($timeoutS)   { $trArgs += @('-w', ([int][Math]::Ceiling($timeoutS * 1000))) }
$trArgs += $dest

& "$env:SystemRoot\System32\tracert.exe" @trArgs
exit $LASTEXITCODE
'@ | Set-Content -Encoding UTF8 (Join-Path $BIN_DIR "traceroute.ps1")

@'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0traceroute.ps1" %*
'@ | Set-Content -Encoding ASCII (Join-Path $BIN_DIR "traceroute.cmd")

Write-Host "[10/12] Ensuring $BIN_DIR on system PATH..."
$curPath = [Environment]::GetEnvironmentVariable("Path","Machine")
if (-not ($curPath -split ';' | Where-Object { $_ -ieq $BIN_DIR })) {
  [Environment]::SetEnvironmentVariable("Path", ($curPath.TrimEnd(';') + ";" + $BIN_DIR), "Machine")
  Write-Host "    - Added to system PATH (Machine)."
}

# ----------------- Scheduled Tasks -----------------
Write-Host "[11/12] Creating Scheduled Tasks..."
Ensure-Dir $LOG_DIR
$logOut = Join-Path $env:USERPROFILE "mtr-logger.log"
$archOut= Join-Path $env:USERPROFILE "mtr-logger-archive.log"

Task-Delete-IfExists $MAIN_TASK
Task-Delete-IfExists $ARCH_TASK

$stepMin = [int](60 / $LPH)
$windowSec = $stepMin * 60
$duration = $windowSec - $SAFETY

$logCmd = "`"$WRAPPER_CMD`" `"$TARGET`" --proto `"$PROTO`" --dns `"$DNS_MODE`" -i `"$INTERVAL`" --timeout `"$TIMEOUT`" -p `"$PROBES`" --duration $duration --export --outfile auto >> `"$logOut`" 2>&1"
Task-Create -Name $MAIN_TASK -Cmd $logCmd -Schedule "MINUTE" -Mo "$stepMin"

$archCmd = "`"$RUN_PY`" -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> `"$archOut`" 2>&1"
Task-Create -Name $ARCH_TASK -Cmd $archCmd -Schedule "DAILY" -StartTime "00:00"

# ----------------- Self-test + PATH refresh (CURRENT SESSION) -----------------
Write-Host "[12/12] PATH refresh and self-test..."
# Refresh PATH for **this** session so wrapper & traceroute are usable immediately:
Refresh-Path
# Prepend BIN_DIR to this session's PATH (ensures our shims win):
if (($env:Path -split ';') -notcontains $BIN_DIR) { $env:Path = "$BIN_DIR;$env:Path" }

try {
  & "$WRAPPER_PS" $TARGET --proto $PROTO --dns $DNS_MODE -i $INTERVAL --timeout $TIMEOUT -p $PROBES --duration 5 --export --outfile auto | Out-Null
  Write-Host "    - Self-test invoked."
} catch {
  Write-Host "    - Self-test not conclusive (ok to ignore)."
}

Write-Host ""
Write-Host "✅ Install complete."
Write-Host "You can run NOW (no new terminal needed):"
Write-Host "  mtr-logger $TARGET --proto $PROTO -i $INTERVAL --timeout $TIMEOUT -p $PROBES"
Write-Host "Uninstall anytime:  mtr-logger uninstall"
Write-Host "Logs: $LOG_DIR"
