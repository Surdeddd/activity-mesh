<#
.SYNOPSIS
    activity-mesh uninstall (Windows — CLI ONLY). Removes activity-log.exe.
    There are no scheduled tasks or services to remove: Windows installs are
    CLI-only (see bootstrap.ps1).
.PARAMETER Purge
    Also delete the local state directory. Default: keep data.
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
if (-not $Prefix) { $Prefix = Join-Path $UserHome 'bin' }

$LogBin   = Join-Path $Prefix 'activity-log.exe'
$StoreDir = Join-Path $UserHome '.local\share\activity-mesh'
$SyncDir  = Join-Path $UserHome 'Sync\activity'

function W-Ok   ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function W-Warn ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function W-Dry  ($m) { Write-Host "[DRY]  $m" -ForegroundColor Yellow }

function Invoke-Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { W-Dry $Description; return }
    try { & $Action; W-Ok $Description } catch { W-Warn "$Description : $($_.Exception.Message)" }
}

if (Test-Path $LogBin) {
    Invoke-Step "remove binary $LogBin" { Remove-Item $LogBin -Force }
} else {
    W-Warn "no binary at $LogBin"
}

if ($Purge) {
    if (Test-Path $StoreDir) {
        Invoke-Step "purge $StoreDir" { Remove-Item -Recurse -Force $StoreDir }
    }
    W-Warn "left $SyncDir alone — it's the cross-host source-of-truth, delete by hand if intended"
} else {
    W-Ok "preserved data: $StoreDir $SyncDir"
}

W-Ok 'uninstall complete'
if ($DryRun) { W-Warn 'dry-run only — re-run without -DryRun to apply' }
