<#
.SYNOPSIS
    activity-mesh bootstrap (Windows — CLI ONLY).
    Windows support is limited to the activity-log CLI: releases ship only
    activity-log.exe for windows/amd64. The watcher and the query daemon are
    macOS/Linux; there are no Task Scheduler units.
.PARAMETER DryRun
    Print the plan without performing any operation.
.PARAMETER Version
    Release tag to install (vX.Y.Z). Default: latest.
.PARAMETER Prefix
    Install dir for activity-log.exe. Default: $env:USERPROFILE\bin.
.EXAMPLE
    pwsh installers\bootstrap.ps1 -DryRun
    pwsh installers\bootstrap.ps1 -Version v0.4.0
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Version = 'latest',
    [string]$Prefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
if (-not $Prefix) { $Prefix = Join-Path $UserHome 'bin' }

$Repo     = if ($env:ACTIVITY_MESH_REPO) { $env:ACTIVITY_MESH_REPO } else { 'Surdeddd/activity-mesh' }
$BaseUrl  = $env:ACTIVITY_MESH_BASE_URL
$HostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$LogBin   = Join-Path $Prefix 'activity-log.exe'
$SyncDir  = Join-Path $UserHome 'Sync\activity'

function W-Ok   ($m) { Write-Host "[OK]   $m" -ForegroundColor Green }
function W-Info ($m) { Write-Host "[i]    $m" -ForegroundColor Cyan }
function W-Dry  ($m) { Write-Host "[DRY]  $m" -ForegroundColor Yellow }
function Fail   ($m) {
    Write-Host "[FAIL] $m" -ForegroundColor Red
    Write-Host "[FAIL] bootstrap FAILED — installation is incomplete" -ForegroundColor Red
    exit 1
}

W-Info "host=$HostName os=windows arch=amd64 version=$Version dry_run=$DryRun (CLI-only platform)"

if ($DryRun) {
    W-Dry "would resolve release tag ($Version) for $Repo"
    W-Dry "would download activity-mesh_<ver>_windows_amd64.zip + checksums.txt"
    W-Dry "would verify sha256 of the archive against checksums.txt"
    W-Dry "would install activity-log.exe -> $LogBin"
    W-Dry "would add $Prefix to the user PATH"
    W-Dry "would run: activity-log init --sync-dir $SyncDir --yes"
    W-Dry "would seed registries from the archive into $SyncDir"
    W-Info "Windows is CLI-only: no watcher, no daemon, no scheduled tasks"
    W-Info "this was a dry-run — re-run without -DryRun to apply"
    exit 0
}

$tag = $Version
if (-not $BaseUrl) {
    if ($tag -eq 'latest') {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -TimeoutSec 30
            $tag = $rel.tag_name
        } catch { Fail "cannot resolve latest release tag: $($_.Exception.Message)" }
    }
    $BaseUrl = "https://github.com/$Repo/releases/download/$tag"
} elseif ($tag -eq 'latest') {
    Fail "ACTIVITY_MESH_BASE_URL requires an explicit -Version"
}
$ver = $tag.TrimStart('v')
$archive = "activity-mesh_${ver}_windows_amd64.zip"

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("amesh-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    W-Info "fetching $BaseUrl/$archive"
    try {
        Invoke-WebRequest -Uri "$BaseUrl/$archive" -OutFile (Join-Path $tmp $archive) -UseBasicParsing -TimeoutSec 120
        Invoke-WebRequest -Uri "$BaseUrl/checksums.txt" -OutFile (Join-Path $tmp 'checksums.txt') -UseBasicParsing -TimeoutSec 60
    } catch { Fail "download failed: $($_.Exception.Message)" }

    $wantLine = Select-String -Path (Join-Path $tmp 'checksums.txt') -Pattern ([regex]::Escape($archive)) | Select-Object -First 1
    if (-not $wantLine) { Fail "no checksum entry for $archive" }
    $want = ($wantLine.Line -split '\s+')[0].ToLower()
    $got = (Get-FileHash -Algorithm SHA256 -Path (Join-Path $tmp $archive)).Hash.ToLower()
    if ($want -ne $got) { Fail "checksum MISMATCH for $archive (want $want got $got)" }
    W-Ok "sha256 verified ($archive)"
    W-Info "signature NOT verified (cosign verification is not implemented on Windows); sha256 checksum was verified"

    $x = Join-Path $tmp 'x'
    Expand-Archive -Path (Join-Path $tmp $archive) -DestinationPath $x -Force
    $exe = Join-Path $x 'activity-log.exe'
    if (-not (Test-Path $exe)) { Fail "activity-log.exe missing from release archive" }

    if (-not (Test-Path $Prefix)) { New-Item -ItemType Directory -Path $Prefix -Force | Out-Null }
    Copy-Item -Path $exe -Destination $LogBin -Force
    W-Ok "binary installed -> $LogBin"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if ($userPath -notlike "*$Prefix*") {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Prefix).TrimStart(';'), 'User')
        W-Ok "added $Prefix to user PATH"
    }

    & $LogBin init --sync-dir $SyncDir --yes
    if ($LASTEXITCODE -ne 0) { Fail "activity-log init failed (exit $LASTEXITCODE)" }
    W-Ok "activity-log init done"

    $regSrc = Join-Path $x 'registries'
    if (Test-Path $regSrc) {
        foreach ($reg in 'kinds', 'scopes', 'agents', 'redaction') {
            $dst = Join-Path $SyncDir "$reg.yaml"
            if (-not (Test-Path $dst)) {
                Copy-Item -Path (Join-Path $regSrc "$reg.yaml") -Destination $dst
                W-Ok "seeded registry -> $dst"
            }
        }
    } else {
        Fail "registries/ missing from release archive"
    }

    & $LogBin --version
    if ($LASTEXITCODE -ne 0) { Fail "installed activity-log does not run" }
    & $LogBin emit --kind status --scope activity-mesh --summary "installed on $HostName (windows cli-only)" | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "smoke emit failed" }
    W-Ok "verification done"
} finally {
    Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
}

W-Info "Windows is CLI-only: emit/query/compact work; watcher, daemon, hooks, and health units are macOS/Linux"
W-Ok "bootstrap complete on $HostName (windows/amd64, version $ver)"
