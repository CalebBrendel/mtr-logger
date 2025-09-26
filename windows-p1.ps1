$ErrorActionPreference='Stop'

# 1) TLS 1.2 for Invoke-WebRequest (older Windows boxes)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# 2) Ensure we are admin
$wid=[Security.Principal.WindowsIdentity]::GetCurrent()
$wpr=new-object Security.Principal.WindowsPrincipal($wid)
if(-not $wpr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ Write-Host "Run this in an elevated PowerShell (Run as administrator)." -Foreground Yellow; exit 1 }

# 3) Install Python 3.12 via official EXE (simple & reliable)
$pyUrl = 'https://www.python.org/ftp/python/3.12.5/python-3.12.5-amd64.exe'
$pyTmp = Join-Path $env:TEMP ('python-'+[guid]::NewGuid().ToString()+'.exe')
Write-Host "Downloading Python..." ; Invoke-WebRequest -UseBasicParsing -Uri $pyUrl -OutFile $pyTmp
Write-Host "Installing Python (silent)..." ; Start-Process $pyTmp -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0" -Wait

# 4) Refresh PATH for *this* session (PS 5.1-safe)
$mp=[Environment]::GetEnvironmentVariable('Path','Machine')
$up=[Environment]::GetEnvironmentVariable('Path','User')
if($mp -and $up){ $env:Path = ($mp.TrimEnd(';')+';'+$up) } elseif($mp){ $env:Path=$mp } elseif($up){ $env:Path=$up } else { $env:Path="" }
Start-Sleep -Seconds 2

# 5) Try to resolve a REAL python.exe (avoid MS Store alias)
function Resolve-Py {
  # prefer py launcher if present
  try { Get-Command py -ErrorAction Stop | Out-Null; $p=& py -3 -c "import sys,os;print(sys.executable if os.path.exists(sys.executable) else '')" 2>$null; if($p){$p=$p.Trim(); if(Test-Path $p){ return $p }} } catch {}
  # registry-ish well-known spots + common paths
  $cands=@(
    "C:\Python313\python.exe","C:\Python312\python.exe","C:\Python311\python.exe","C:\Python310\python.exe",
    "C:\Program Files\Python313\python.exe","C:\Program Files\Python312\python.exe","C:\Program Files\Python311\python.exe","C:\Program Files\Python310\python.exe",
    "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe","$env:LOCALAPPDATA\Programs\Python\Python312\python.exe","$env:LOCALAPPDATA\Programs\Python\Python311\python.exe","$env:LOCALAPPDATA\Programs\Python\Python310\python.exe"
  )
  foreach($c in $cands){ if(Test-Path $c){ return $c } }
  # last resort: python on PATH if it points to a real file
  try { $pc=Get-Command python -ErrorAction Stop; if($pc.Source -and (Test-Path $pc.Source)){ return $pc.Source } } catch {}
  return $null
}
$pyExe = Resolve-Py
if(-not $pyExe){ throw "Python did not become visible to this session. Close this window, open a NEW elevated PowerShell, and re-run this same block." }

# 6) Quick version sanity (no heredocs)
$ver = & $pyExe -c "import sys;print('.'.join(map(str,sys.version_info[:3])))"
Write-Host ("Python resolved: {0} (v{1})" -f $pyExe, $ver.Trim())

# 7) Fetch and run your main installer (your PS 5.1–compatible script)
$installerUrl = 'https://calebbrendel.com/mtr-logger/windows-p2.ps1'  # change if you host elsewhere
Write-Host "Downloading and launching main installer: $installerUrl"
$script = Invoke-WebRequest -UseBasicParsing -Uri $installerUrl | Select-Object -ExpandProperty Content
if([string]::IsNullOrWhiteSpace($script)){ throw "Failed to download main installer from $installerUrl" }
Invoke-Expression $script
