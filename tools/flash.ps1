<#
.SYNOPSIS
    Flash fallback adapter (Spec §10). Preferred path is Agentic HIL; this
    wrapper exists only for targets Agentic HIL does not support yet.

    Usage:
        .\tools\flash.ps1 -Backend openocd -Artifact artifacts\build\firmware.elf -Json
        .\tools\flash.ps1 -Backend agentic-hil -Artifact artifacts\build\firmware.elf -Json

    Hard constraints (Spec §10/§24):
      - artifact must be one of the conventional names under artifacts/build/
      - mass erase / security programming flags are rejected before execution
      - every external process has a timeout
      - returns JSON (firmware-flash-result/v1) and saves the raw log

    Without a configured backend this exits CONFIG_ERROR - flash is intentionally
    not configured until real hardware integration (Spec §31 step 7).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('agentic-hil', 'openocd', 'stm32cubeprogrammer', 'esptool', 'jlink', 'vendor')]
    [string]$Backend,
    [string]$Artifact = 'artifacts/build/firmware.elf',
    [switch]$Json,
    [int]$TimeoutMs = 120000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$artifactPath = if ([System.IO.Path]::IsPathRooted($Artifact)) { $Artifact } else { Join-Path $repoRoot $Artifact }

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# --- artifact guard (Spec §10) -------------------------------------------------
$allowed = @('firmware.elf', 'firmware.hex', 'firmware.bin')
$name = Split-Path $artifactPath -Leaf
if ($name -notin $allowed) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message "artifact name '$name' is not flashable; allowed: $($allowed -join ', ')" -Detail $artifactPath
}
if (-not (Test-Path -LiteralPath $artifactPath)) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message 'artifact does not exist; run tools/build.ps1 first.' -Detail $artifactPath
}
$full = (Resolve-Path -LiteralPath $artifactPath).Path
$buildRoot = (Join-Path $repoRoot 'artifacts\build')
if (-not $full.StartsWith((Resolve-Path -LiteralPath $buildRoot).Path, [System.StringComparison]::OrdinalIgnoreCase)) {
    Exit-WithError -Class 'PERMISSION_DENIED' -Message 'artifact is outside artifacts/build; refusing to flash.' -Detail $full
}

# --- backend dispatch ----------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\flash-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

switch ($Backend) {
    'agentic-hil' {
        $cmd = Get-Command agentic-hil -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Exit-WithError -Class 'PROBE_NOT_FOUND' -Message "'agentic-hil' is not installed; install Agentic HIL or choose a vendor fallback." -Detail 'See README.md -> M2'
        }
        # NOTE: verify the exact CLI schema against the installed version at setup
        # (Spec §32). The following is the documented v0.4+ shape:
        $args = @('flash', '--artifact', $full, '--json')
        $res = Invoke-FwProcess -FilePath $cmd.Source -Arguments $args -WorkingDirectory $repoRoot -TimeoutMs $TimeoutMs -StdoutFile $logFile
    }
    default {
        Exit-WithError -Class 'CONFIG_ERROR' -Message "backend '$Backend' is not configured on this machine yet." -Detail 'Flash is intentionally not configured until real hardware integration (Spec M2).'
    }
}

if ($res.timed_out) {
    Exit-WithError -Class 'FLASH_ERROR' -Message 'flash backend timed out and was killed.' -Detail $logFile
}
if ($res.exit_code -ne 0) {
    Exit-WithError -Class 'FLASH_ERROR' -Message 'flash backend reported failure.' -Detail ($res.stdout + $res.stderr)
}

$result = [ordered]@{
    schema      = 'firmware-flash-result/v1'
    ok          = $true
    backend     = $Backend
    artifact    = $full
    artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    log         = (Resolve-Path -LiteralPath $logFile).Path
    generated_at = Get-FwTimestamp
}
if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
exit 0