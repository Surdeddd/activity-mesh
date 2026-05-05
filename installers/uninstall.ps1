<#
.SYNOPSIS
    activity-mesh uninstall (Windows). Stops tasks, removes binary + scheduler entries.
.PARAMETER Purge
    Also delete state + config directories. Default: keep data.
.PARAMETER DryRun
    Print plan without performing destructive operations.
.PARAMETER Prefix
    Install dir for the binary. Default: $env:USERPROFILE\bin.
#>
[CmdletBinding()]
param(
    [switch]$Purge,
    [switch]$DryRun,
    [string]$Prefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$LocalApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $UserHome '.local/share' }
$RoamApp  = if ($env:APPDATA)      { $env:APPDATA }      else { Join-Path $UserHome '.config' }
if (-not $Prefix) { $Prefix = Join-Path $UserHome 'bin' }

$LogBin     = Join-Path $Prefix 'activity-log.exe'
$WatcherBin = Join-Path $Prefix 'activity-watcher.exe'
$StateDir  = Join-Path $LocalApp 'activity-mesh'
$LogDir    = Join-Path $StateDir 'logs'
$SyncDir   = Join-Path $UserHome 'Sync/activity'
$ConfigDir = Join-Path $RoamApp 'activity-mesh'

function W-Ok   ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function W-Warn ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function W-Dry  ($m) { Write-Host "[DRY]  $m" -ForegroundColor Yellow }

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { W-Dry $Description; return }
    try { & $Action; W-Ok $Description } catch { W-Warn "$Description : $($_.Exception.Message)" }
}

# stop + delete scheduled tasks
foreach ($unit in @('watcher','daemon')) {
    $taskName = "activity-mesh\$unit"
    if ($DryRun) {
        W-Dry "schtasks /End /TN $taskName"
        W-Dry "schtasks /Delete /TN $taskName /F"
        continue
    }
    try { & schtasks.exe /End    /TN $taskName 2>$null | Out-Null } catch { }
    try { & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null } catch { }
    W-Ok "removed task $taskName"
}

# also try to remove the parent folder
if (-not $DryRun) {
    try { & schtasks.exe /Delete /TN 'activity-mesh' /F 2>$null | Out-Null } catch { }
}

# remove binaries
foreach ($p in @($LogBin, $WatcherBin)) {
    if (Test-Path $p) {
        Invoke-Step "remove binary $p" { Remove-Item $p -Force }
    } else {
        W-Warn "no binary at $p"
    }
}

# data
if ($Purge) {
    foreach ($d in @($StateDir,$LogDir,$ConfigDir)) {
        if (Test-Path $d) {
            Invoke-Step "purge $d" { Remove-Item -Recurse -Force $d }
        }
    }
    W-Warn "left $SyncDir alone — it's the cross-host source-of-truth, delete by hand if intended"
} else {
    W-Ok "preserved data: $StateDir $SyncDir $ConfigDir"
}

W-Ok 'uninstall complete'
if ($DryRun) { W-Warn 'dry-run only — re-run without -DryRun to apply' }
