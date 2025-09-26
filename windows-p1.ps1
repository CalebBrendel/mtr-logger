<#  bootstrap_mtr-logger.ps1
    One-go Windows setup for mtr-logger:
      1) Ensure elevation & TLS 1.2
      2) Install Python 3 (winget -> official EXE fallback)
      3) Verify a real python.exe exists (not MS Store alias)
      4) Download and run your main installer script
    PowerShell 5.1 compatible
#>

param(
  # Your main installer (PS 5.1–compatible) URL:
  [string]$InstallerUrl = "https://calebbrendel.com/mtr-logger/windowsp2",

  # Fallback Python EXE (adjust if you need another version)
  [string]$PythonExeUrl = "https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe",

  # Minimum acceptable Python major.minor (just in case)
  [version]$MinPy = [version]"3.8"
)

$ErrorActionPreference = "Stop"

# ----------------- Helpers -----------------
function Require-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script in an **elevated** PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}
function Ensure-TLS12 {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
}
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

# Resolve a REAL python.exe path (not the MS Store alias)
function Resolve-PythonPath {
  # Try py launcher enumerations first
  try {
    $pyCmd = Get-Command py -ErrorAction Stop
    $list = & py -0p 2>$null
    if ($list) {
      foreach ($line in ($list -split "`n")) {
        $exe = $line.Trim()
        if ($exe -and (Test-Path $exe) -and ($exe -like "*\python.exe")) { return $exe }
      }
    }
    # Fallback: ask py -3 for concrete executable
    try {
      $p = & py -3 -c "import sys;print(sys.executable)" 2>$null
      if ($p) { $p = $p.Trim(); if (Test-Path $p) { return $p } }
    } catch {}
  } catch {}

  # Try python on PATH
  try {
    $pcmd = Get-Command python -ErrorAction Stop
    if ($pcmd -and (Test-Path $pcmd.Source)) { return $pcmd.Source }
  } catch {}

  # Common install locations
  $candidates = @(
    "C:\Python313\python.exe",
    "C:\Python312\python.exe",
    "C:\Program Files\Python313\python.exe",
    "C:\Program Files\Python312\python.exe",
    "C:\Program Files\Python311\python.exe",
    "C:\Program Files\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

  return $null
}

function Install-Python {
  # If already resolvable, we’re good
  if (Resolve-PythonPath) { return }

  $haveWinget = $false
  try { Get-Command winget -ErrorAction Stop | Out-Null; $haveWinget = $true } catch {}

  if ($haveWinget) {
    Write-Host "Installing Python 3 via winget..."
    winget install -e --id Python.Python.3 --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Refresh-Path
    Start-Sleep -Seconds 2
    if (Resolve-PythonPath) { return }
    Write-Host "winget reported success, but Python isn't resolvable yet. Will try EXE fallback..." -ForegroundColor Yellow
  } else {
    Write-Host "winget not available—using EXE fallback." -ForegroundColor Yellow
  }

  # Official EXE fallback
  $tmp = Join-Path $env:TEMP ("python-installer-" + [guid]::NewGuid().ToString() + ".exe")
  Write-Host "Downloading Python EXE..."
  Invoke-WebRequest -UseBasicParsing -Uri $PythonExeUrl -OutFile $tmp
  Write-Host "Installing Python (silent)..."
  Start-Process $tmp -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait
  Refresh-Path
  Start-Sleep -Seconds 2

  if (-not (Resolve-PythonPath)) {
    throw "Python installation appears to have failed or is not yet available to this session."
  }
}

function Check-Python-Version {
  param([string]$PyPath)
  try {
    $v = & $PyPath - << 'PY'
import sys
print(".".join(map(str, sys.version_info[:3])))
PY
    $v = ($v | Select-Object -First 1).Trim()
    if ($v -match '^\d+\.\d+(\.\d+)?$') {
      if ([version]$v -lt $MinPy) {
        throw "Python $v is below the required minimum of $MinPy."
      }
      return $true
    }
  } catch { throw $_ }
}

function Run-Installer {
  param([string]$Url)
  Write-Host "Downloading and running installer from: $Url"
  $script = Invoke-WebRequest -UseBasicParsing -Uri $Url | Select-Object -ExpandProperty Content
  if ([string]::IsNullOrWhiteSpace($script)) { throw "Failed to download installer script from $Url" }
  Invoke-Expression $script
}

# ----------------- Main -----------------
Require-Admin
Ensure-TLS12

Write-Host "== mtr-logger one-go bootstrap =="
Write-Host "[1/3] Ensuring Python is installed..."
Install-Python

# Verify a concrete python.exe and basic version
$PythonExe = Resolve-PythonPath
if (-not $PythonExe) {
  throw "Python still not resolvable after installation. Open a new elevated PowerShell and rerun this script."
}
Check-Python-Version -PyPath $PythonExe | Out-Null
Write-Host ("    - Using Python: {0}" -f $PythonExe)

# IMPORTANT: do NOT call `python`/`py` in this step to avoid MS Store alias noise.
# The main installer does its own env/venv work anyway.

Write-Host "[2/3] Refreshing PATH for this session..."
Refresh-Path

Write-Host "[3/3] Launching mtr-logger installer..."
Run-Installer -Url $InstallerUrl
