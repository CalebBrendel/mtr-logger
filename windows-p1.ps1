<#  windows-p1.ps1 — One-go bootstrap for mtr-logger (PowerShell 5.1 compatible)
    - Ensures elevation & TLS 1.2
    - Installs Python 3 (winget -> official EXE fallback)
    - Resolves a REAL python.exe (py launcher, registry, well-known paths)
    - Verifies minimum Python version
    - Downloads & runs second-stage installer

    Usage (elevated):
      Set-ExecutionPolicy Bypass -Scope Process -Force
      irm https://raw.githubusercontent.com/CalebBrendel/mtr-logger/refs/heads/main/windows-p1.ps1 | iex
#>

param(
  [string]$InstallerUrl = "https://calebbrendel.com/mtr-logger/windows",
  [string]$PythonExeUrl = "https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe",
  [version]$MinPy = [version]"3.8"
)

$ErrorActionPreference = "Stop"

# ---------- Helpers ----------
function Require-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
    exit 1
  }
}
function Ensure-TLS12 {
  try {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  } catch {}
}
function Refresh-Path {
  $m = [Environment]::GetEnvironmentVariable('Path','Machine')
  $u = [Environment]::GetEnvironmentVariable('Path','User')
  if ($m -and $u)      { $env:Path = ($m.TrimEnd(';') + ';' + $u) }
  elseif ($m)          { $env:Path = $m }
  elseif ($u)          { $env:Path = $u }
  else                 { $env:Path = "" }
}

# Registry probing for Python installs (HKLM/HKCU, 32/64-bit)
function Get-PythonFromRegistry {
  $roots = @(
    "HKLM:\SOFTWARE\Python\PythonCore",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore",
    "HKCU:\SOFTWARE\Python\PythonCore",
    "HKCU:\SOFTWARE\WOW6432Node\Python\PythonCore"
  )
  $candidates=@()
  foreach ($root in $roots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
      $verKey = $_.PsPath
      try {
        $ip = Join-Path $verKey "InstallPath"
        if (Test-Path $ip) {
          $props = Get-ItemProperty $ip
          $p = $null
          if ($props.ExecutablePath) { $p = $props.ExecutablePath }
          if (-not $p -and $props.Path) { $p = Join-Path $props.Path "python.exe" }
          if (-not $p -and $props.'(default)') { $p = Join-Path $props.'(default)' "python.exe" }
          if ($p -and (Test-Path $p)) { $candidates += $p }
        }
      } catch {}
    }
  }
  $candidates | Select-Object -Unique
}

# Return a REAL python.exe path without invoking "python" stub
function Resolve-PythonPath {
  # 1) py launcher enumeration (only if 'py' exists)
  try {
    $pyCmd = Get-Command py -ErrorAction Stop
    $list = & py -0p 2>$null
    if ($list) {
      foreach ($line in ($list -split "`n")) {
        $exe = $line.Trim()
        if ($exe -and (Test-Path $exe) -and ($exe -like "*\python.exe")) { return $exe }
      }
    }
    # Fallback: ask py for concrete path (safe; py exists)
    try {
      $p = & py -3 -c "import sys,os; p=sys.executable; print(p if p and os.path.exists(p) else '')" 2>$null
      if ($p) { $p=$p.Trim(); if ($p -and (Test-Path $p)) { return $p } }
    } catch {}
  } catch {}

  # 2) Registry
  $fromReg = Get-PythonFromRegistry
  foreach ($p in $fromReg) { if ($p -and (Test-Path $p)) { return $p } }

  # 3) Well-known paths
  $common = @(
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python311\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach ($p in $common) { if (Test-Path $p) { return $p } }

  # 4) Last resort: python on PATH (real file)
  try {
    $pcmd = Get-Command python -ErrorAction Stop
    if ($pcmd.Source -and (Test-Path $pcmd.Source)) { return $pcmd.Source }
  } catch {}

  return $null
}

function Install-Python {
  if (Resolve-PythonPath) { return }

  $haveWinget = $false
  try { Get-Command winget -ErrorAction Stop | Out-Null; $haveWinget = $true } catch {}

  if ($haveWinget) {
    Write-Host "Installing Python 3 via winget..."
    winget install -e --id Python.Python.3 --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Refresh-Path; Start-Sleep -Seconds 2
    if (Resolve-PythonPath) { return }
    Write-Host "winget reported success, but python.exe is not resolvable yet. Trying EXE fallback..." -ForegroundColor Yellow
  } else {
    Write-Host "winget not available — using official EXE fallback." -ForegroundColor Yellow
  }

  $tmp = Join-Path $env:TEMP ("python-installer-" + [guid]::NewGuid().ToString() + ".exe")
  Write-Host "Downloading Python EXE..."
  Invoke-WebRequest -UseBasicParsing -Uri $PythonExeUrl -OutFile $tmp
  Write-Host "Installing Python (silent)..."
  Start-Process $tmp -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait
  Refresh-Path; Start-Sleep -Seconds 2

  if (-not (Resolve-PythonPath)) {
    throw "Python installation appears to have failed or is not resolvable in this session."
  }
}

function Check-Python-Version {
  param([string]$PyPath, [version]$MinVersion)
  # Call the concrete path directly; never 'python' or 'py'
  $v = & $PyPath -c "import sys; print('.'.join(map(str, sys.version_info[:3])))"
  $v = ($v | Select-Object -First 1).Trim()
  if (-not ($v -match '^\d+\.\d+(\.\d+)?$')) { throw "Could not parse Python version string: '$v'" }
  if ([version]$v -lt $MinVersion) { throw "Python $v is below the required minimum of $MinVersion." }
  return $true
}

function Run-Installer {
  param([string]$Url)
  Write-Host "Downloading and running installer from: $Url"
  $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url
  $script = $null
  if ($resp -and $resp.Content) { $script = $resp.Content }
  if ([string]::IsNullOrWhiteSpace($script)) { throw "Failed to download installer script from $Url" }
  Invoke-Expression $script
}

# ---------- Main ----------
Require-Admin
Ensure-TLS12

Write-Host "== mtr-logger one-go bootstrap =="
Write-Host "[1/3] Ensuring Python is installed..."
Install-Python

$PythonExe = Resolve-PythonPath
if (-not $PythonExe) {
  throw "Python is still not resolvable. Close this window, open a NEW elevated PowerShell, and rerun."
}

Check-Python-Version -PyPath $PythonExe -MinVersion $MinPy | Out-Null
Write-Host ("    - Using Python: {0}" -f $PythonExe)

Write-Host "[2/3] Refreshing PATH for this session..."
Refresh-Path

Write-Host "[3/3] Launching mtr-logger installer..."
Run-Installer -Url $InstallerUrl
