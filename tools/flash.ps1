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
    [Parameter(Mandatory = $true)][ValidateSet('simulator', 'agentic-hil', 'openocd', 'stm32cubeprogrammer', 'esptool', 'jlink', 'vendor')]
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
    'simulator' {
        # GAP-003 (v0.0.2): simulator flash is a no-op acknowledgement - the
        # simulated DUT is the compiled artifact itself, exercised by the HIL
        # harness. Never presented as real flashing.
        Save-FwLog -Path $logFile -Content 'simulator backend: flash validated via firmware build + HIL run (no real programmer involved)'
        $result = [ordered]@{
            schema      = 'firmware-flash-result/v1'
            ok          = $true
            backend     = 'simulator'
            artifact    = $full
            artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            simulated   = $true
            hardware_validated = $false
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'agentic-hil' {
        # GAP-003 (v0.0.2): NO guessed CLI. Agentic HIL 0.14 has no 'flash'
        # subcommand; flashing is done through its MCP tools (flash_firmware /
        # artifact_upload) in Qoder, or through the Test Reactor plan in
        # headless runs. This wrapper intentionally refuses to guess.
        Exit-WithError -Class 'REAL_HARDWARE_REQUIRED' `
            -Message "flash via Agentic HIL is not driven from this wrapper; use the Qoder MCP tool flash_firmware, or a test-reactor plan (test-plans/real-smoke.yaml)." `
            -Detail "GAP-003: guessed CLI paths are banned (agentic-hil 0.14.0 CLI has no flash subcommand)."
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