<#
.SYNOPSIS
    DUT reset (Spec §26 M2). Preferred backend is Agentic HIL; the
    simulator backend is a no-op acknowledgement (the HIL harness owns the
    simulated DUT process and resets it in-test).

    Usage:
        .\tools\reset.ps1 -Backend simulator -Json
        .\tools\reset.ps1 -Backend agentic-hil -Json

    Exit codes: 0 ok, 1 backend failure, 2 config/identity error.
#>
[CmdletBinding()]
param(
    [ValidateSet('simulator', 'agentic-hil', 'openocd', 'vendor')]
    [string]$Backend = 'simulator',
    [string]$ExpectedTarget,          # verify probe identity before reset (Spec §9)
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\reset-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

switch ($Backend) {
    'simulator' {
        # The simulated DUT is owned by the pytest harness; a standalone reset
        # is a no-op that still records the audit entry.
        Save-FwLog -Path $logFile -Content "simulator backend: reset is managed by the HIL harness (pytest conftest SimulatedDut.reset)."
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'simulator'
            target      = 'simulated-dut'
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'agentic-hil' {
        $cmd = Get-Command agentic-hil -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Exit-WithError -Class 'PROBE_NOT_FOUND' -Message "'agentic-hil' is not installed; install Agentic HIL or use -Backend simulator." -Detail 'See README.md -> M2'
        }
        # NOTE: verify exact CLI schema at setup time (Spec §32). Documented shape:
        $res = Invoke-FwProcess -FilePath $cmd.Source -Arguments @('reset', '--target', $ExpectedTarget, '--json') -WorkingDirectory $repoRoot -TimeoutMs 120000 -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'RESET_ERROR' -Message 'reset backend timed out and was killed.' -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'RESET_ERROR' -Message 'reset backend reported failure.' -Detail ($res.stdout + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'agentic-hil'
            target      = $ExpectedTarget
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    default {
        Exit-WithError -Class 'CONFIG_ERROR' -Message "backend '$Backend' is not configured on this machine yet (Spec M2)." -Detail 'Flash/reset are intentionally not configured until real hardware integration.'
    }
}