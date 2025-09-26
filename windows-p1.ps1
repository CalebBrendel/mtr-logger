$ErrorActionPreference='Stop'

# --- TLS 1.2 for older WinHTTP ---
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# --- Require elevation ---
$wid=[Security.Principal.WindowsIdentity]::GetCurrent()
$wpr=New-Object Security.Principal.WindowsPrincipal($wid)
if(-not $wpr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  Write-Host "Run this in an elevated PowerShell (Run as administrator)." -ForegroundColor Yellow
  exit 1
}

# --- Temp working folder ---
$work = Join-Path $env:TEMP ("mtr-bootstrap-"+[guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null

# --- Download & install Python 3.12.5 (silent) ---
$pyUrl = 'https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe'
$pyExe = Join-Path $work 'python-3.12.5-amd64.exe'
Write-Host "Downloading Python installer..." ; Invoke-WebRequest -UseBasicParsing -Uri $pyUrl -OutFile $pyExe
Write-Host "Installing Python (silent)..." ; Start-Process $pyExe -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait

# --- Refresh PATH in *this* process (PS 5.1-safe) ---
$mp=[Environment]::GetEnvironmentVariable('Path','Machine'); $up=[Environment]::GetEnvironmentVariable('Path','User')
if($mp -and $up){ $env:Path = ($mp.TrimEnd(';')+';'+$up) }
elseif($mp){ $env:Path=$mp } elseif($up){ $env:Path=$up } else { $env:Path="" }
Start-Sleep -Seconds 2

# --- Resolve a real python.exe (avoid Store alias) ---
function Resolve-Python {
  # 1) py launcher (if present)
  try {
    Get-Command py -ErrorAction Stop | Out-Null
    $p = & py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null
    if($p){ $p=$p.Trim(); if(Test-Path $p){ return $p } }
  } catch {}
  # 2) common locations
  $cands=@(
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPDATA\Programs\Python\Python311\python.exe","$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach($c in $cands){ if(Test-Path $c){ return $c } }
  # 3) PATH (only if it points to a real file)
  try { $pc=Get-Command python -ErrorAction Stop; if($pc.Source -and (Test-Path $pc.Source)){ return $pc.Source } } catch {}
  return $null
}
$pyReal = Resolve-Python
if(-not $pyReal){
  throw "Python not visible to this process yet. Close this window, open a NEW elevated PowerShell, and rerun this block."
}
$ver = & $pyReal -c "import sys;print('.'.join(map(str,sys.version_info[:3])))"
Write-Host ("Python OK: {0} (v{1})" -f $pyReal, $ver.Trim())

# --- Download stage-2 installer to a file (NO iex) ---
$stage2Url = 'https://calebbrendel.com/mtr-logger/windows-p2.ps1'   # change if needed
$stage2Path = Join-Path $work 'windows-p2.ps1'
Write-Host "Downloading main installer..."
Invoke-WebRequest -UseBasicParsing -Uri $stage2Url -OutFile $stage2Path
if(-not (Test-Path $stage2Path)){ throw "Failed to download $stage2Url" }

# --- Execute stage-2 from file (ExecutionPolicy Bypass for this process only) ---
Write-Host "Launching main installer..."
powershell -ExecutionPolicy Bypass -NoProfile -File $stage2Path
