<#  bootstrap_mtr-logger.ps1
    One-go installer for mtr-logger on Windows:
      - Ensures elevation
      - Installs Python 3 (winget if available; official EXE fallback)
      - Refreshes PATH
      - Downloads and executes your full mtr-logger installer script
    PowerShell 5.1 compatible
#>

param(
  # Where your full installer script lives (the PS 5.1–compatible one you’re serving)
  [string]$InstallerUrl = "https://calebbrendel.com/mtr-logger/windows",

  # Optional: explicit Python EXE version to use for fallback
  [string]$PythonExeUrl = "https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe"
)

$ErrorActionPreference = "Stop"

# ----------------- Helper funcs -----------------
function Require-Admin {
  $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script in an **elevated** PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

function Ensure-TLS12 {
  try {
    # Force TLS 1.2 for Invoke-WebRequest on older boxes
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {}
}

function Install-Python {
  $havePy = $false
  try { Get-Command py -ErrorAction Stop | Out-Null; $havePy = $true } catch {}
  if (-not $havePy) { try { Get-Command python -ErrorAction Stop | Out-Null; $havePy = $true } catch {} }
  if ($havePy) { return }

  $haveWinget = $false
  try { Get-Command winget -ErrorAction Stop | Out-Null; $haveWinget = $true } catch {}

  if ($haveWinget) {
    Write-Host "Installing Python 3 via winget..."
    winget install -e --id Python.Python.3 --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Refresh-Path
    return
  }

  Write-Host "winget not available — installing Python via official EXE..." -ForegroundColor Yellow
  $tmp = Join-Path $env:TEMP ("python-installer-" + [guid]::NewGuid().ToString() + ".exe")
  Invoke-WebRequest -UseBasicParsing -Uri $PythonExeUrl -OutFile $tmp
  Start-Process $tmp -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait
  Refresh-Path
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
Write-Host "[1/2] Ensuring Python is installed..."
Install-Python

# Quick sanity print (non-fatal if one is missing)
try { & py -V } catch {}
try { & python -V } catch {}

Write-Host "[2/2] Launching mtr-logger installer..."
Run-Installer -Url $InstallerUrl
