# windows-p1-fixed.ps1  (PowerShell 5.1 safe)
# One-go bootstrap:
# - Installs Python 3.12.5 (official EXE)
# - Clears MS Store python alias stubs
# - Refreshes PATH
# - Resolves real python.exe
# - Downloads & runs stage-2 installer from URL

param(
  [string]$Stage2Url = "https://calebbrendel.com/mtr-logger/windows-p2.ps1",
  [string]$PythonExeUrl = "https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe",
  [version]$MinPy = [version]"3.8"
)

$ErrorActionPreference = 'Stop'

# --- Helpers ---
function Require-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Run in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}
function EnsureTLS12 { try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {} }
function Refresh-Path {
  $m=[Environment]::GetEnvironmentVariable('Path','Machine')
  $u=[Environment]::GetEnvironmentVariable('Path','User')
  if ($m -and $u) { $env:Path = ($m.TrimEnd(';') + ';' + $u) }
  elseif ($m)     { $env:Path = $m }
  elseif ($u)     { $env:Path = $u }
  else            { $env:Path = "" }
}
function Remove-StoreAliasStubs {
  # These stubs cause the "Python was not found; run without arguments..." dialog
  $wa = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
  $stubs = @("python.exe","python3.exe","python3.11.exe","python3.12.exe","python3.13.exe")
  foreach ($s in $stubs) {
    $p = Join-Path $wa $s
    try { if (Test-Path $p) { Remove-Item -Force $p } } catch {}
  }
}
function Resolve-Python {
  # Prefer py launcher if present
  try {
    Get-Command py -ErrorAction Stop | Out-Null
    $p = & py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null
    if ($p) { $p=$p.Trim(); if (Test-Path $p) { return $p } }
  } catch {}

  # Common install locations (Program Files / per-user)
  $cands = @(
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPDATA\Programs\Python\Python311\python.exe","$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }

  # Last resort: PATH, but only if it is a real file (not a Store shim)
  try {
    $pc = Get-Command python -ErrorAction Stop
    if ($pc.Source -and (Test-Path $pc.Source)) { return $pc.Source }
  } catch {}

  return $null
}
function Check-Python-Version {
  param([string]$PyPath, [version]$MinVersion)
  $v = & $PyPath -c "import sys;print('.'.join(map(str,sys.version_info[:3])))"
  $v = ($v | Select-Object -First 1).Trim()
  if (-not ($v -match '^\d+\.\d+(\.\d+)?$')) { throw "Could not parse Python version string: '$v'" }
  if ([version]$v -lt $MinVersion) { throw "Python $v is below required minimum $MinVersion" }
  return $true
}

# --- Main ---
Require-Admin
EnsureTLS12

Write-Host "== mtr-logger bootstrap (p1) =="

# Work dir
$work = Join-Path $env:TEMP ("mtr-bootstrap-"+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null

# Install Python
Write-Host "[1/4] Installing Python..."
$pyExe = Join-Path $work "python-installer.exe"
Invoke-WebRequest -UseBasicParsing -Uri $PythonExeUrl -OutFile $pyExe
Start-Process $pyExe -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait

# Kill Store alias stubs (fixes immediate 'python not found' confusion)
Write-Host "[2/4] Removing MS Store python alias stubs..."
Remove-StoreAliasStubs

# Path refresh & resolve python
Write-Host "[3/4] Resolving python.exe path..."
Refresh-Path
Start-Sleep -Seconds 2
$pyReal = Resolve-Python
if (-not $pyReal) { throw "Python not visible to this session. Open a NEW elevated PowerShell and re-run." }
Check-Python-Version -PyPath $pyReal -MinVersion $MinPy | Out-Null
Write-Host ("    - Python: {0}" -f $pyReal)

# Download and run stage-2 as a FILE (avoid iex parsing quirks)
Write-Host "[4/4] Downloading stage-2 installer..."
$stage2 = Join-Path $work "windows-p2.ps1"
Invoke-WebRequest -UseBasicParsing -Uri $Stage2Url -OutFile $stage2
if (-not (Test-Path $stage2)) { throw "Failed to download stage-2 from $Stage2Url" }

Write-Host "Launching stage-2..."
powershell -ExecutionPolicy Bypass -NoProfile -File $stage2
