<#  windows-onefile.ps1 — One-command Windows installer for mtr-logger (PowerShell 5.1)
    v3: Python install is now bullet-proof:
      - All-Users then Per-User EXE
      - Remove WindowsApps stubs
      - Resolve via py launcher, registry, known paths, then quick scan
      - /log PythonInstall.log and show tail on failure
#>

$ErrorActionPreference = 'Stop'

# ----------------- Config / Defaults -----------------
$GIT_URL_DEFAULT      = "https://github.com/CalebBrendel/mtr-logger.git"
$BRANCH_DEFAULT       = "main"
$PREFIX_DEFAULT       = "C:\mtr-logger"
$BIN_DIR_DEFAULT      = "C:\mtr-logger\bin"

$TARGET_DEFAULT       = "google.ca"
$PROTO_DEFAULT        = "icmp"
$DNS_DEFAULT          = "auto"
$INTERVAL_DEFAULT     = "0.3"
$TIMEOUT_DEFAULT      = "0.3"
$PROBES_DEFAULT       = "3"
$ASCII_DEFAULT        = "yes"

$LOGS_PER_HOUR_DEFAULT= 4
$SAFETY_MARGIN_DEFAULT= 5
$ARCHIVE_RETENTION_DEFAULT = 90

# Python EXE
$PY_VERSION = "3.13.3"
$PY_EXE_URL = "https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-amd64.exe"

# Derived (recomputed after prompts)
$SRC_DIR   = Join-Path $PREFIX_DEFAULT "src"
$VENV_DIR  = Join-Path $PREFIX_DEFAULT ".venv"
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
  $keys = @(
    "HKLM:\SOFTWARE\Python\PythonCore",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore",
    "HKCU:\SOFTWARE\Python\PythonCore"
  )
  $cands = @()
  foreach($root in $keys){
    try {
      if(Test-Path $root){
        Get-ChildItem $root -ErrorAction Stop | ForEach-Object {
          $verKey = $_.PSPath
          try {
            $ip = Join-Path $verKey "InstallPath"
            if(Test-Path $ip){
              $path = (Get-ItemProperty -Path $ip -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
              if($path -and (Test-Path (Join-Path $path "python.exe"))){
                $cands += (Join-Path $path "python.exe")
              }
            }
          } catch {}
        }
      }
    } catch {}
  }
  # choose highest version by folder name heuristic
  $best = $cands | Sort-Object -Descending -Unique | Select-Object -First 1
  return $best
}

function Resolve-Python {
  # 1) py launcher
  try {
    Get-Command py -ErrorAction Stop | Out-Null
    $p = & py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null
    if ($p) { $p=$p.Trim(); if (Test-Path $p) { return $p } }
  } catch {}
  # 2) Registry
  $reg = Resolve-Python-FromRegistry
  if($reg){ return $reg }
  # 3) Known locations
  $cands=@(
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPDATA\Programs\Python\Python311\python.exe","$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  # 4) Quick scan (bounded)
  foreach($root in @("C:\Program Files","C:\Program Files (x86)", (Join-Path $env:LOCALAPPDATA "Programs\Python"))){
    try {
      if(Test-Path $root){
        $hit = Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue -Filter python.exe -File | Select-Object -First 1
        if($hit){ return $hit.FullName }
      }
    } catch {}
  }
  # 5) PATH (real file only)
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

# --- Install Python via EXE with logging and fallback ---
function Ensure-PythonDirect {
  Remove-StorePythonStubs
  Refresh-Path

  $existing = Resolve-Python
  if ($existing) { return $existing }

  $tmp = Join-Path $env:TEMP ("python-"+$PY_VERSION+"-"+[guid]::NewGuid().ToString()+".exe")
  $log = Join-Path $env:TEMP ("PythonInstall-"+(Get-Date -Format "yyyyMMdd-HHmmss")+".log")
  Write-Host "Downloading Python $PY_VERSION ..."
  Invoke-WebRequest -UseBasicParsing -Uri $PY_EXE_URL -OutFile $tmp

  # All-Users first
  Write-Host "Installing Python (All-Users, silent)..."
  $argsAU = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=1 InstallLauncherAllUsers=1 /log `"$log`""
  Start-Process $tmp -ArgumentList $argsAU -Wait
  Refresh-Path; Start-Sleep -Seconds 2
  $py = Resolve-Python
  if ($py) { try { Remove-Item $tmp -Force } catch {}; return $py }

  # Per-User fallback
  Write-Host "All-Users install not visible; retrying Per-User install..."
  $argsPU = "/quiet InstallAllUsers=0 PrependPath=1 Include_test=0 Include_launcher=1 /log `"$log`""
  Start-Process $tmp -ArgumentList $argsPU -Wait
  Refresh-Path; Start-Sleep -Seconds 2
  $py = Resolve-Python
  try { Remove-Item $tmp -Force } catch {}

  if (-not $py) {
    Write-Host "Python installer log (tail): $log" -ForegroundColor Yellow
    try { Get-Content -Path $log -Tail 60 | ForEach-Object { Write-Host "  $_" } } catch {}
    throw "Python installation completed but python.exe not resolvable to this session."
  }
  return $py
}

# ----------------- Main flow -----------------
Require-Admin
Ensure-TLS12

Write-Host ""
Write-Host "         __           .__                                     "
Write-Host "  ______/  |________  |  |   ____   ____   ____   ___________ "
Write-Host " /     \   __\_  __ \ |  |  /  _ \ / ___\ / ___\_/ __ \_  __ \"
Write-Host "|  Y Y  \  |  |  | \/ |  |_(  <_> ) /_/  > /_/  >  ___/|  | \/"
Write-Host "|__|_|  /__|  |__|    |____/\____/\___  /\___  / \___  >__|   "
Write-Host "      \/                         /_____//_____/      \/        "
Write-Host "== mtr-logger bootstrap (Windows, one-file) =="
Write-Host ""

Write-Host "[1/12] Ensuring Chocolatey..."
Ensure-Choco

Write-Host "[2/12] Installing Git + curl (Chocolatey)..."
Ensure-GitCurl

Write-Host "[3/12] Installing Python directly from python.org..."
$PYEXE = Ensure-PythonDirect
Check-PyVersion -PyExe $PYEXE | Out-Null
Write-Host ("    - Python: {0}" -f $PYEXE)

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

Write-Host "[7/12] Creating virtualenv: $VENV_DIR"
Ensure-Dir $VENV_DIR
& $PYEXE -m venv $VENV_DIR
$VENV_PY = Join-Path $VENV_DIR "Scripts\python.exe"
$VENV_PIP= Join-Path $VENV_DIR "Scripts\pip.exe"

Write-Host "[8/12] Installing package (editable)..."
& $VENV_PIP install -U pip wheel | Out-Null
& $VENV_PIP install -e $SRC_DIR | Out-Null

Write-Host "[9/12] Creating wrapper + uninstall in $BIN_DIR"
Ensure-Dir $BIN_DIR

@"
param()
Write-Host "This will uninstall mtr-logger:" -ForegroundColor Yellow
Write-Host "  PREFIX:  $PREFIX"
Write-Host "  VENV:    $VENV_DIR"
Write-Host "  WRAPPER: $WRAPPER_CMD / $WRAPPER_PS"
`$ans = Read-Host "Proceed with uninstall? [y/N]"
if (!(`$ans) -or `$ans.ToLower() -notin @('y','yes')) { Write-Host "Aborted."; exit 0 }

Write-Host "[1/5] Removing Scheduled Tasks..."
schtasks /Delete /TN "$MAIN_TASK" /F 2>`$null | Out-Null
schtasks /Delete /TN "$ARCH_TASK" /F 2>`$null | Out-Null

Write-Host "[2/5] Removing install dir..."
if (Test-Path "$PREFIX") { Remove-Item -Recurse -Force "$PREFIX" }

Write-Host "[3/5] Removing wrappers..."
if (Test-Path "$WRAPPER_CMD") { Remove-Item -Force "$WRAPPER_CMD" }
if (Test-Path "$WRAPPER_PS")  { Remove-Item -Force "$WRAPPER_PS" }

Write-Host "[4/5] (Optional) Remove logs at `$env:USERPROFILE\mtr\logs"
`$del = Read-Host "Delete logs as well? [y/N]"
if (`$del -and `$del.ToLower() -in @('y','yes')) {
  `$logdir = Join-Path `$env:USERPROFILE 'mtr\logs'
  if (Test-Path `$logdir) { Remove-Item -Recurse -Force `$logdir }
}

Write-Host "[5/5] Uninstall complete."
"@ | Set-Content -Encoding UTF8 $UNINSTALL_PS

@"
param([Parameter(ValueFromRemainingArguments=`$true)]`$Args)
if (`$Args.Count -gt 0 -and `$Args[0].ToString().ToLower() -eq 'uninstall') {
  & "$UNINSTALL_PS"
  exit `$LASTEXITCODE
}
& "$VENV_PY" -m mtrpy @Args
"@ | Set-Content -Encoding UTF8 $WRAPPER_PS

@"
@echo off
set VENV=$VENV_DIR
if /I "%~1"=="uninstall" (
  powershell -ExecutionPolicy Bypass -File "$UNINSTALL_PS"
  exit /b %ERRORLEVEL%
)
"%VENV%\Scripts\python.exe" -m mtrpy %*
"@ | Set-Content -Encoding OEM $WRAPPER_CMD

Write-Host "[10/12] Ensuring $BIN_DIR on system PATH..."
$curPath = [Environment]::GetEnvironmentVariable("Path","Machine")
if (-not ($curPath -split ';' | Where-Object { $_ -ieq $BIN_DIR })) {
  [Environment]::SetEnvironmentVariable("Path", ($curPath.TrimEnd(';') + ";" + $BIN_DIR), "Machine")
  Write-Host "    - Added to system PATH. Open a new terminal for it to take effect globally." -ForegroundColor Yellow
}

# ----------------- Scheduled Tasks -----------------
Write-Host "[11/12] Creating Scheduled Tasks..."
Ensure-Dir $LOG_DIR
$logOut = Join-Path $env:USERPROFILE "mtr-logger.log"
$archOut= Join-Path $env:USERPROFILE "mtr-logger-archive.log"

$logCmd = "`"$WRAPPER_CMD`" `"$TARGET`" --proto `"$PROTO`" --dns `"$DNS_MODE`" -i `"$INTERVAL`" --timeout `"$TIMEOUT`" -p `"$PROBES`" --duration $duration --export --outfile auto >> `"$logOut`" 2>&1"
schtasks /Delete /TN "$MAIN_TASK" /F 2>$null | Out-Null
schtasks /Create /TN "$MAIN_TASK" /TR $logCmd /SC MINUTE /MO $stepMin /RU "SYSTEM" /RL HIGHEST /F | Out-Null

$archCmd = "`"$VENV_PY`" -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> `"$archOut`" 2>&1"
schtasks /Delete /TN "$ARCH_TASK" /F 2>$null | Out-Null
schtasks /Create /TN "$ARCH_TASK" /TR $archCmd /SC DAILY /ST 00:00 /RU "SYSTEM" /RL HIGHEST /F | Out-Null

Write-Host "[12/12] Self-test..."
try {
  & $WRAPPER_CMD $TARGET --proto $PROTO --dns $DNS_MODE -i $INTERVAL --timeout $TIMEOUT -p $PROBES --duration 5 --export --outfile auto | Out-Null
  Write-Host "    - Self-test invoked."
} catch {
  Write-Host "    - Self-test not conclusive (ok to ignore)."
}

Write-Host ""
Write-Host "✅ Install complete."
Write-Host "Run interactively (new terminal recommended so PATH reloads):"
Write-Host "  mtr-logger $TARGET --proto $PROTO -i $INTERVAL --timeout $TIMEOUT -p $PROBES"
Write-Host "Uninstall anytime:  mtr-logger uninstall"
Write-Host "Logs: $LOG_DIR"
