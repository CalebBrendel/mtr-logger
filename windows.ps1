<#  setup_mtr-logger.ps1
    Windows bootstrap for mtr-logger (drop-in)
    - Run in an elevated PowerShell (Run as administrator)
    - Ensures Python & Git (winget if available; Git has ZIP fallback)
    - Creates venv, installs package in editable mode
    - Adds wrapper (mtr-logger.cmd / .ps1) to PATH
    - Creates Scheduled Tasks for logging + daily archiver
    - Timezone chooser (tzutil) similar to your Linux menu
#>

# ----------------- Config / Defaults -----------------
$ErrorActionPreference = 'Stop'

$GIT_URL_DEFAULT      = "https://github.com/CalebBrendel/mtr-logger.git"
$BRANCH_DEFAULT       = "main"
$PREFIX_DEFAULT       = "C:\mtr-logger"
$WRAPPER_DIR_DEFAULT  = "C:\mtr-logger\bin"

$TARGET_DEFAULT       = "google.ca"
$PROTO_DEFAULT        = "icmp"           # icmp|tcp|udp
$DNS_DEFAULT          = "auto"
$INTERVAL_DEFAULT     = "0.3"
$TIMEOUT_DEFAULT      = "0.3"
$PROBES_DEFAULT       = "3"
$FPS_DEFAULT          = "6"             # not used on Windows; kept for parity
$ASCII_DEFAULT        = "yes"           # used when you run interactively

$LOGS_PER_HOUR_DEFAULT    = "4"         # must evenly divide 60
$SAFETY_MARGIN_DEFAULT    = "5"
$ARCHIVE_RETENTION_DEFAULT= "90"        # days

# Derived paths (resolved later after prompts)
$SRC_DIR   = Join-Path $PREFIX_DEFAULT "src"
$VENV_DIR  = Join-Path $PREFIX_DEFAULT ".venv"
$BIN_DIR   = $WRAPPER_DIR_DEFAULT
$WRAPPER_PS= Join-Path $BIN_DIR "mtr-logger.ps1"
$WRAPPER_CMD=Join-Path $BIN_DIR "mtr-logger.cmd"
$UNINSTALL_PS = Join-Path $BIN_DIR "uninstall.ps1"
$LOG_DIR   = Join-Path $env:USERPROFILE "mtr\logs"
$MAIN_TASK = "mtr-logger\Log"
$ARCH_TASK = "mtr-logger\Archive"

# ----------------- Logo -----------------
function Show-Logo {
@"
         __           .__                                     
  ______/  |________  |  |   ____   ____   ____   ___________ 
 /     \   __\_  __ \ |  |  /  _ \ / ___\ / ___\_/ __ \_  __ \
|  Y Y  \  |  |  | \/ |  |_(  <_> ) /_/  > /_/  >  ___/|  | \/
|__|_|  /__|  |__|    |____/\____/\___  /\___  / \___  >__|   
      \/                         /_____//_____/      \/        
"@
}

# ----------------- Helpers -----------------
function Require-Admin {
  if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "Please run this script in an **elevated** PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}
function Read-Default([string]$Prompt, [string]$Default) {
  $v = Read-Host "$Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v.Trim() }
}
function Read-YesNo([string]$Prompt, [string]$Default="Y") {
  $opt = Read-Host "$Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($opt)) { $opt = $Default }
  switch ($opt.ToLower()) { 'y' {return 'Y'} 'yes' {return 'Y'} 'n' {return 'N'} 'no' {return 'N'} default {return $Default.ToUpper()} }
}
function Ensure-Dir($p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
function Validate-FactorOf60([int]$n) { return ($n -in 1,2,3,4,5,6,10,12,15,20,30,60) }
function Minute-Marks([int]$perHour) {
  $step = [int](60 / $perHour)
  $mins = 0..59 | Where-Object { $_ % $step -eq 0 }
  return ($mins -join ",")
}
function Refresh-ProcessPath {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

# ----------------- Dependencies (Git + Python) -----------------
function Ensure-Git {
  # Return a usable git.exe path (installs Git if needed; ZIP fallback)
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) { return $git.Source }

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host " - Installing Git via winget..."
    winget install -e --id Git.Git --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Refresh-ProcessPath
  } else {
    Write-Host " - winget not found; falling back to ZIP clone..." -ForegroundColor Yellow
    return $null  # we’ll use ZIP fallback later
  }

  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { throw "Git installation failed or PATH not updated." }
  return $git.Source
}
function Ensure-Python {
  $py = Get-Command py -ErrorAction SilentlyContinue
  $pyExe = Get-Command python -ErrorAction SilentlyContinue
  if ($py -or $pyExe) { return }

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host " - Installing Python 3 via winget..."
    winget install -e --id Python.Python.3 --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Refresh-ProcessPath
  } else {
    throw "Python not found and winget unavailable. Please install Python 3 and re-run."
  }
}

# ----------------- Timezone via tzutil -----------------
function Get-CurrentTZ { (tzutil /g) 2>$null }
function List-TimeZones { (tzutil /l) 2>$null }
function Apply-TimeZone($tz) {
  try { tzutil /s $tz; Write-Host "    - Timezone set to: $tz" }
  catch { Write-Host "WARNING: Failed to set timezone via tzutil. You can set it later in Windows settings." -ForegroundColor Yellow }
}
function Choose-TimeZone {
  param([string]$Detected)
  Write-Host ""
  Write-Host ("[TZ] Detected host timezone: {0}" -f $Detected)
  $yn = Read-YesNo "Is this the correct timezone?" "Y"
  if ($yn -eq 'Y') { return $Detected }

  Write-Host ""
  Write-Host "Choose how to set timezone:"
  Write-Host "  1) Use detected timezone ($Detected)"
  Write-Host "  2) Enter exact Windows timezone name (e.g., 'Central Standard Time')"
  Write-Host "  3) Browse list"
  Write-Host "  4) Search by keyword"
  Write-Host "  5) Skip timezone change"
  while ($true) {
    $opt = Read-Default "Option" "4"
    switch ($opt) {
      1 { return $Detected }
      2 {
        $tz = Read-Default "Enter exact Windows timezone name" ""
        if ([string]::IsNullOrWhiteSpace($tz)) { Write-Host "    - Empty, try again."; continue }
        $all = List-TimeZones
        if ($all -and ($all -contains $tz)) {
          if ((Read-YesNo "Use this timezone?" "Y") -eq 'Y') { Apply-TimeZone $tz; return $tz }
        } else {
          Write-Host "    - Not found in tzutil list. Try again."
        }
      }
      3 {
        $all = List-TimeZones
        if (-not $all) { Write-Host "    - tzutil list unavailable."; continue }
        $i = 1; foreach ($z in $all) { "{0,3}. {1}" -f $i, $z; $i++ }
        $pick = Read-Default "Pick number" ""
        if ($pick -match '^\d+$') {
          $idx = [int]$pick
          if ($idx -ge 1 -and $idx -le $all.Count) {
            $choice = $all[$idx-1]
            if ((Read-YesNo "Use this timezone?" "Y") -eq 'Y') { Apply-TimeZone $choice; return $choice }
          }
        } else { Write-Host "    - Invalid number." }
      }
      4 {
        $kw = Read-Default "Search keyword (e.g., Chicago or Central)" ""
        if ([string]::IsNullOrWhiteSpace($kw)) { Write-Host "    - Empty search."; continue }
        $all = List-TimeZones
        $matches = $all | Where-Object { $_ -match [Regex]::Escape($kw) }
        if (-not $matches) { Write-Host "    - No matches."; continue }
        $i = 1; foreach ($z in $matches) { "{0,3}. {1}" -f $i, $z; $i++ }
        $pick = Read-Default "Pick number (or 0 to cancel)" "0"
        if ($pick -match '^\d+$') {
          $idx = [int]$pick
          if ($idx -eq 0) { continue }
          if ($idx -ge 1 -and $idx -le $matches.Count) {
            $choice = $matches[$idx-1]
            if ((Read-YesNo "Use this timezone?" "Y") -eq 'Y') { Apply-TimeZone $choice; return $choice }
          }
        }
      }
      5 { return $Detected }
      default { Write-Host "    - Invalid option. Choose 1–5." }
    }
  }
}

# ----------------- ZIP fallback for repo (no Git path) -----------------
function ZipClone($RepoUrl, $Branch, $DestDir) {
  # Supports public GitHub HTTPS URLs of form .../owner/repo.git
  if ($RepoUrl -notmatch "https://github\.com/.+?/.+?(\.git)?$") {
    throw "ZIP fallback only supports public GitHub HTTPS URLs."
  }
  $base = $RepoUrl -replace '\.git$',''
  $zip = "$base/archive/refs/heads/$Branch.zip"
  $tmpZip = Join-Path $env:TEMP "mtr-logger-$Branch.zip"
  Invoke-WebRequest -Uri $zip -OutFile $tmpZip
  if (Test-Path $DestDir) { Remove-Item -Recurse -Force $DestDir }
  $tmpDir = Join-Path $env:TEMP ("mtr-src-" + [guid]::NewGuid().ToString())
  Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
  # GitHub zips to repo-branch folder; move contents to DestDir
  $inner = Get-ChildItem -Path $tmpDir | Where-Object { $_.PSIsContainer } | Select-Object -First 1
  if (-not $inner) { throw "Unexpected ZIP layout." }
  New-Item -ItemType Directory -Path $DestDir | Out-Null
  Copy-Item -Recurse -Force -Path (Join-Path $inner.FullName "*") -Destination $DestDir
  Remove-Item -Recurse -Force $tmpZip, $tmpDir
}

# ----------------- Main -----------------
Require-Admin
Show-Logo
Write-Host "== mtr-logger bootstrap (Windows) =="

# (1) Dependencies
Write-Host "[1/10] Checking dependencies..."
Ensure-Python
$Global:GIT_EXE = Ensure-Git  # may be $null to signal ZIP fallback

# (2) Timezone
Write-Host "[2/10] Timezone setup..."
$detectedTZ = Get-CurrentTZ; if (-not $detectedTZ) { $detectedTZ = "UTC" }
$CRON_TZ = Choose-TimeZone -Detected $detectedTZ
Write-Host ("    - Using timezone: {0}" -f $CRON_TZ)

# (3) Prompts
Write-Host ""
$GIT_URL  = Read-Default "Git URL" $GIT_URL_DEFAULT
if ($GIT_URL -notmatch '^https://|^git@') { Write-Host "WARNING: invalid URL; using default."; $GIT_URL = $GIT_URL_DEFAULT }
$BRANCH   = Read-Default "Branch"  $BRANCH_DEFAULT
$PREFIX   = Read-Default "Install prefix" $PREFIX_DEFAULT
$BIN_DIR  = Read-Default "Wrapper dir added to PATH" $WRAPPER_DIR_DEFAULT

$TARGET   = Read-Default "Target (hostname/IP)" $TARGET_DEFAULT
$PROTO    = Read-Default "Probe protocol (icmp|tcp|udp)" $PROTO_DEFAULT
$DNS_MODE = Read-Default "DNS mode (auto|on|off)" $DNS_DEFAULT
$INTERVAL = Read-Default "Interval seconds (-i)" $INTERVAL_DEFAULT
$TIMEOUT  = Read-Default "Timeout seconds (--timeout)" $TIMEOUT_DEFAULT
$PROBES   = Read-Default "Probes per hop (-p)" $PROBES_DEFAULT
$FPS      = Read-Default "TUI FPS (interactive only)" $FPS_DEFAULT | Out-Null
$ASCII    = Read-Default "Use ASCII borders? (yes/no)" $ASCII_DEFAULT

$LPH      = [int](Read-Default "How many logs per hour (must divide 60 evenly)" $LOGS_PER_HOUR_DEFAULT)
if (-not (Validate-FactorOf60 $LPH)) { Write-Host "ERROR: $LPH does not evenly divide 60." -ForegroundColor Red; exit 2 }
$SAFETY   = [int](Read-Default "Safety margin seconds (subtract from each window)" $SAFETY_MARGIN_DEFAULT)

$SRC_DIR  = Join-Path $PREFIX "src"
$VENV_DIR = Join-Path $PREFIX ".venv"
$WRAPPER_PS = Join-Path $BIN_DIR "mtr-logger.ps1"
$WRAPPER_CMD= Join-Path $BIN_DIR "mtr-logger.cmd"
$UNINSTALL_PS = Join-Path $BIN_DIR "uninstall.ps1"
$LOG_DIR  = Join-Path $env:USERPROFILE "mtr\logs"

$stepMin = [int](60 / $LPH)
$windowSec = $stepMin * 60
$duration = $windowSec - $SAFETY
if ($duration -le 0) { Write-Host "ERROR: Safety too large for frequency." -ForegroundColor Red; exit 2 }
$minuteMarks = Minute-Marks $LPH

Write-Host ""
Write-Host ("Schedule (TZ={0})" -f $CRON_TZ)
Write-Host ("  Minute marks: {0}" -f $minuteMarks)
Write-Host ("  Window seconds: {0}" -f $windowSec)
Write-Host ("  Duration seconds: {0}" -f $duration)
Write-Host ""

# (4) Clone/update
Write-Host "[3/10] Preparing install root: $PREFIX"
Ensure-Dir $PREFIX
Write-Host "[4/10] Cloning/updating repo..."

if ($GIT_EXE) {
  if (Test-Path (Join-Path $SRC_DIR ".git")) {
    & $GIT_EXE -C $SRC_DIR remote set-url origin $GIT_URL | Out-Null
    & $GIT_EXE -C $SRC_DIR fetch origin --depth=1 | Out-Null
    & $GIT_EXE -C $SRC_DIR checkout -q $BRANCH
    & $GIT_EXE -C $SRC_DIR reset --hard "origin/$BRANCH" | Out-Null
  } else {
    if (Test-Path $SRC_DIR) { Remove-Item -Recurse -Force $SRC_DIR }
    & $GIT_EXE clone --depth=1 --branch $BRANCH $GIT_URL $SRC_DIR | Out-Null
  }
} else {
  # ZIP fallback
  ZipClone -RepoUrl $GIT_URL -Branch $BRANCH -DestDir $SRC_DIR
}

if (-not (Test-Path (Join-Path $SRC_DIR "pyproject.toml"))) {
  Write-Host "pyproject.toml not found in $SRC_DIR" -ForegroundColor Red
  exit 1
}

# (5) venv + editable install
Write-Host "[5/10] Creating virtualenv: $VENV_DIR"
Ensure-Dir $VENV_DIR
$pyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($pyLauncher) { py -3 -m venv $VENV_DIR } else { python -m venv $VENV_DIR }
$PYEXE  = Join-Path $VENV_DIR "Scripts\python.exe"
$PIPEXE = Join-Path $VENV_DIR "Scripts\pip.exe"
& $PIPEXE install -U pip wheel | Out-Null
Write-Host "[6/10] Installing package (editable)..."
& $PIPEXE install -e $SRC_DIR | Out-Null

# (6) Wrapper + Uninstall
Write-Host "[7/10] Creating wrapper in $BIN_DIR"
Ensure-Dir $BIN_DIR

@"
param([Parameter(ValueFromRemainingArguments=\$true)]\$Args)
if (\$Args.Count -gt 0 -and \$Args[0].ToString().ToLower() -eq 'uninstall') {
  & "$UNINSTALL_PS"
  exit \$LASTEXITCODE
}
& "$PYEXE" -m mtrpy @Args
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

@"
param()
Write-Host "This will uninstall mtr-logger:" -ForegroundColor Yellow
Write-Host "  PREFIX:  $PREFIX"
Write-Host "  VENV:    $VENV_DIR"
Write-Host "  WRAPPER: $WRAPPER_CMD / $WRAPPER_PS"
\$ans = Read-Host "Proceed with uninstall? [y/N]"
if (!(\$ans) -or \$ans.ToLower() -notin @('y','yes')) { Write-Host "Aborted."; exit 0 }

Write-Host "[1/6] Removing Scheduled Tasks..."
schtasks /Delete /TN "$MAIN_TASK" /F 2>$null | Out-Null
schtasks /Delete /TN "$ARCH_TASK" /F 2>$null | Out-Null

Write-Host "[2/6] Removing install dir..."
if (Test-Path "$PREFIX") { Remove-Item -Recurse -Force "$PREFIX" }

Write-Host "[3/6] Removing wrappers..."
if (Test-Path "$WRAPPER_CMD") { Remove-Item -Force "$WRAPPER_CMD" }
if (Test-Path "$WRAPPER_PS")  { Remove-Item -Force "$WRAPPER_PS" }

Write-Host "[4/6] Optional: remove logs at $env:USERPROFILE\mtr\logs"
\$del = Read-Host "Delete logs as well? [y/N]"
if (\$del -and \$del.ToLower() -in @('y','yes')) {
  \$logdir = Join-Path \$env:USERPROFILE 'mtr\logs'
  if (Test-Path \$logdir) { Remove-Item -Recurse -Force \$logdir }
}

Write-Host "[5/6] Remove PATH entry (if desired) via System Settings (it will be harmless to leave)."
Write-Host "[6/6] Uninstall complete."
"@ | Set-Content -Encoding UTF8 $UNINSTALL_PS

# Add BIN_DIR to PATH (system)
Write-Host "[8/10] Ensuring $BIN_DIR is on PATH..."
$curPath = [Environment]::GetEnvironmentVariable("Path","Machine")
if (-not ($curPath -split ';' | Where-Object { $_ -ieq $BIN_DIR })) {
  [Environment]::SetEnvironmentVariable("Path", ($curPath.TrimEnd(';') + ";" + $BIN_DIR), "Machine")
  Write-Host "    - Added to system PATH. Open a new terminal to pick it up." -ForegroundColor Yellow
}

# (7) Scheduled Tasks
Write-Host "[9/10] Creating Scheduled Tasks..."
Ensure-Dir $LOG_DIR

# Main repeating task every $stepMin minutes
# Use >> to append to a simple log in user profile (SYSTEM tasks won’t have the same profile; we’ll still write out somewhere user-accessible)
$UserLog = Join-Path $env:USERPROFILE "mtr-logger.log"
$logCmd = "`"$WRAPPER_CMD`" `"$TARGET`" --proto `"$PROTO`" --dns `"$DNS_MODE`" -i `"$INTERVAL`" --timeout `"$TIMEOUT`" -p `"$PROBES`" --duration $duration --export --outfile auto >> `"$UserLog`" 2>&1"
schtasks /Delete /TN "$MAIN_TASK" /F 2>$null | Out-Null
schtasks /Create /TN "$MAIN_TASK" /TR $logCmd /SC MINUTE /MO $stepMin /RU "SYSTEM" /RL HIGHEST /F | Out-Null

# Archiver daily at 00:00
$UserArchLog = Join-Path $env:USERPROFILE "mtr-logger-archive.log"
$archCmd = "`"$PYEXE`" -m mtrpy.archiver --retention $ARCHIVE_RETENTION_DEFAULT >> `"$UserArchLog`" 2>&1"
schtasks /Delete /TN "$ARCH_TASK" /F 2>$null | Out-Null
schtasks /Create /TN "$ARCH_TASK" /TR $archCmd /SC DAILY /ST 00:00 /RU "SYSTEM" /RL HIGHEST /F | Out-Null

# (8) Self-test
Write-Host "[10/10] Self-test (non-fatal if it fails) ..."
try {
  & $WRAPPER_CMD $TARGET --proto $PROTO --dns $DNS_MODE -i $INTERVAL --timeout $TIMEOUT -p $PROBES --duration 5 --export --outfile auto | Out-Null
  Write-Host "    - Self-test invoked."
} catch {
  Write-Host "    - Self-test not conclusive (ok to ignore)."
}

Show-Logo
Write-Host ""
Write-Host "✅ Install complete, nerd! Big Chungus sends his regards!🐰🥕"
Write-Host ""
Write-Host "Run interactively (new terminal recommended so PATH reloads):"
Write-Host "  mtr-logger $TARGET --proto $PROTO -i $INTERVAL --timeout $TIMEOUT -p $PROBES"
Write-Host ""
Write-Host "Scheduled Tasks (local time: $CRON_TZ):"
Write-Host "  $MAIN_TASK   — every $stepMin minute(s)"
Write-Host "  $ARCH_TASK   — daily at 00:00"
Write-Host ""
Write-Host "Uninstall anytime:"
Write-Host "  mtr-logger uninstall"
Write-Host ""
Write-Host "Notes:"
Write-Host " - Logs: $LOG_DIR     |  Wrapper dir on PATH: $BIN_DIR"
Write-Host " - If interactive ICMP requires elevation, try:  --proto tcp"
