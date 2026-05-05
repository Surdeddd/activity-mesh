<#
.SYNOPSIS
    activity-mesh bootstrap (Windows). Idempotent: re-running upgrades binaries, preserves config + state.
.PARAMETER DryRun
    Print plan without performing destructive operations.
.PARAMETER Version
    Release tag to install. Default: latest.
.PARAMETER Prefix
    Install dir for the binaries. Default: $env:USERPROFILE\bin.
.EXAMPLE
    pwsh installers\bootstrap.ps1 -DryRun
    pwsh installers\bootstrap.ps1 -Version v1.0.0
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Version = 'latest',
    [string]$Prefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# fallback resolution: real Windows uses $env:USERPROFILE / LOCALAPPDATA / APPDATA;
# on macOS/Linux pwsh those are null, so fall back to $HOME so dry-run works for verification.
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$LocalApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $UserHome '.local/share' }
$RoamApp  = if ($env:APPDATA)      { $env:APPDATA }      else { Join-Path $UserHome '.config' }
if (-not $Prefix) { $Prefix = Join-Path $UserHome 'bin' }

$Repo        = 'Surdeddd/activity-mesh'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Host64      = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$Arch        = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
$LogBin      = Join-Path $Prefix 'activity-log.exe'
$WatcherBin  = Join-Path $Prefix 'activity-watcher.exe'
$StateDir    = Join-Path $LocalApp 'activity-mesh'
$LogDir      = Join-Path $StateDir 'logs'
$SyncDir     = Join-Path $UserHome 'Sync\activity'
$ConfigDir   = Join-Path $RoamApp 'activity-mesh'

function W-Ok    ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function W-Err   ($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
function W-Warn  ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function W-Info  ($m) { Write-Host "[i]    $m" -ForegroundColor Cyan }
function W-Dry   ($m) { Write-Host "[DRY]  $m" -ForegroundColor Yellow }

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { W-Dry $Description; return }
    try { & $Action; W-Ok $Description } catch { W-Err "$Description : $($_.Exception.Message)" }
}

W-Info "host=$Host64 os=windows arch=$Arch version=$Version dry_run=$DryRun"

# ---- 1. download + install binaries ----------------------------------------
function Get-Asset {
    param([string]$Name, [string]$Dest)
    $asset = "$Name-windows-$Arch.exe"
    if ($DryRun) { W-Dry "would download $asset -> $Dest"; return $true }
    $tmp = New-TemporaryFile
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $ghArgs = @('release','download')
        if ($Version -ne 'latest') { $ghArgs += $Version }
        $ghArgs += @('--repo',$Repo,'--pattern',$asset,'--output',$tmp.FullName)
        try {
            & gh @ghArgs 2>$null
            if ((Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue) -eq 0) {
                Move-Item -Path $tmp.FullName -Destination $Dest -Force
                W-Ok "binary installed -> $Dest"; return $true
            }
        } catch { }
        W-Warn "gh download failed for $asset, falling back to Invoke-WebRequest"
    }
    $tagseg = if ($Version -eq 'latest') { 'latest' } else { $Version }
    $url = "https://github.com/$Repo/releases/$tagseg/download/$asset"
    W-Info "fetching $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp.FullName -UseBasicParsing -TimeoutSec 60
        Move-Item -Path $tmp.FullName -Destination $Dest -Force
        W-Ok "binary installed -> $Dest"; return $true
    } catch {
        W-Warn "release not found at $url. Build locally: go build -o $Dest ./cmd/$Name"
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
        return $false
    }
}

if (-not (Test-Path $Prefix)) {
    Invoke-Step "mkdir $Prefix" { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null }
}
[void](Get-Asset -Name 'activity-log'     -Dest $LogBin)
[void](Get-Asset -Name 'activity-watcher' -Dest $WatcherBin)

# ---- 2. scaffold directories ----------------------------------------------
foreach ($d in @($StateDir,$LogDir,$SyncDir,$ConfigDir)) {
    if (Test-Path $d) { W-Ok "exists $d" }
    else { Invoke-Step "mkdir $d" { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
}

# default watcher.yaml
$srcCfg = Join-Path $ScriptDir '..\configs\watcher.yaml'
$dstCfg = Join-Path $ConfigDir 'watcher.yaml'
if ((Test-Path $srcCfg) -and -not (Test-Path $dstCfg)) {
    Invoke-Step "install default watcher.yaml" { Copy-Item -Path $srcCfg -Destination $dstCfg }
}

# ensure prefix on PATH for current user
if (-not $DryRun) {
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if ($userPath -and ($userPath -notlike "*$Prefix*")) {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$Prefix", 'User')
        W-Ok "added $Prefix to user PATH"
    }
}

if ((Test-Path $LogBin) -and -not $DryRun) {
    Invoke-Step 'activity-log init' { & $LogBin init --state $StateDir --sync $SyncDir }
} else {
    W-Info 'skip activity-log init (binary missing or dry-run)'
}

# ---- 3. render + register Task Scheduler tasks ----------------------------
function Expand-Template {
    param([string]$TmplPath, [string]$DestPath)
    if (-not (Test-Path $TmplPath)) { W-Warn "template not found: $TmplPath"; return $false }
    $c = Get-Content -Raw -Path $TmplPath
    $userTag = if ($env:USERDOMAIN) { "$env:USERDOMAIN\$env:USERNAME" } else { $env:USERNAME }
    $map = @{
        '{{BIN_PATH}}'    = $LogBin
        '{{WATCHER_BIN}}' = $WatcherBin
        '{{STATE_DIR}}'   = $StateDir
        '{{SYNC_DIR}}'    = $SyncDir
        '{{CONFIG_DIR}}'  = $ConfigDir
        '{{LOG_DIR}}'     = $LogDir
        '{{HOME}}'        = $UserHome
        '{{USER}}'        = $userTag
    }
    foreach ($k in $map.Keys) { $c = $c.Replace($k, $map[$k]) }
    if ($DryRun) { W-Dry "would write $DestPath ($($c.Length) bytes)"; return $true }
    Set-Content -Path $DestPath -Value $c -Encoding Unicode
    return $true
}

foreach ($unit in @('watcher','daemon')) {
    $tmpl = Join-Path $ScriptDir "templates\taskscheduler-$unit.xml.tmpl"
    $dest = Join-Path $StateDir "task-$unit.xml"
    if (Expand-Template $tmpl $dest) { W-Ok "rendered $dest" }
    $taskName = "activity-mesh\$unit"
    if ($DryRun) { W-Dry "schtasks /Create /TN $taskName /XML $dest /F"; continue }
    try {
        & schtasks.exe /Create /TN $taskName /XML $dest /F | Out-Null
        $exit = (Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue)
        if ($exit -eq 0) { W-Ok "task $taskName registered" } else { W-Warn "schtasks /Create failed for $taskName" }
        & schtasks.exe /Run /TN $taskName 2>$null | Out-Null
    } catch { W-Warn "could not register $taskName : $($_.Exception.Message)" }
}

# ---- 4. verify -------------------------------------------------------------
if ((Test-Path $LogBin) -and -not $DryRun) {
    W-Info "running: $LogBin status"
    try { & $LogBin status } catch { W-Warn "status returned non-zero: $($_.Exception.Message)" }
    try {
        & $LogBin emit --kind status --scope bootstrap --summary "installed on $Host64"
    } catch { W-Warn "smoke emit failed: $($_.Exception.Message)" }
    W-Ok 'verification done'
} else {
    W-Info 'skip verify (binary missing or dry-run)'
}

W-Ok "bootstrap complete on $Host64 (windows/$Arch)"
if ($DryRun) { W-Info 'this was a dry-run — re-run without -DryRun to apply' }
