<#
.SYNOPSIS
    CAN bus adapter (Spec §12). Minimum capability: session_start, send, read,
    filter, session_stop. Backend is Agentic HIL (or a vendor CLI): the exact
    verbs/schema MUST be confirmed against the installed version at setup time
    (Spec §32). With no CAN backend configured this returns CONFIG_ERROR.

    Safety: CAN TX defaults to manual authorization (Spec §12/§24); the
    --authorized flag is required for send so the AI agent cannot TX silently.

    Usage:
        .\tools\can.ps1 session-start -Json
        .\tools\can.ps1 send --arbitration-id 0x123 --frame-count 1 --authorized -Json
        .\tools\can.ps1 read --duration-ms 500 -Json
        .\tools\can.ps1 session-stop -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('session-start', 'send', 'read', 'session-stop', 'filter')]
    [string]$Command,
    [ValidateSet('agentic-hil', 'vendor')]
    [string]$Backend = 'agentic-hil',
    [string]$Adapter,
    [string]$Channel,
    [int]$Bitrate = 500000,
    [string]$ArbitrationId,          # hex string, e.g. 0x123
    [string]$Data,                   # hex bytes, e.g. "11 22 33"
    [int]$FrameCount = 1,
    [int]$DurationMs = 500,
    [switch]$Authorized,             # required for TX (default denied)
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# CAN TX default requires explicit authorization (Spec §12: 人工授权)
if ($Command -eq 'send' -and -not $Authorized) {
    Exit-WithError -Class 'PERMISSION_DENIED' -Message 'CAN TX requires explicit human authorization; pass -Authorized after approval (Spec §12/§24).'
}

$cmd = Get-Command agentic-hil -ErrorAction SilentlyContinue
$tool = if ($cmd) { $cmd.Source } else { $null }

if ($Backend -eq 'agentic-hil' -and -not $tool) {
    Exit-WithError -Class 'PROBE_NOT_FOUND' -Message "'agentic-hil' is not installed; CAN is not available until Agentic HIL is installed (Spec §32)." -Detail 'Install Agentic HIL, then verify its CAN schema with: agentic-hil --help'
}

# Resolve lab config for adapter/channel/bitrate defaults (never hardcoded)
$labCfg = Join-Path $repoRoot 'lab\lab.yaml'
if (-not (Test-Path -LiteralPath $labCfg)) { $labCfg = Join-Path $repoRoot 'lab\lab.example.yaml' }
$canCfg = @{}
if (Test-Path -LiteralPath $labCfg) {
    try {
        $parsed = Get-Content -LiteralPath $labCfg -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($parsed -and $parsed.can) { $canCfg = $parsed.can }
    } catch { }
} else { $canCfg = @{ adapter = $null; channel = $null; bitrate = $Bitrate } }
if (-not $Adapter) { $Adapter = $canCfg.adapter }
if (-not $Channel) { $Channel = $canCfg.channel }
if ($Bitrate -eq 500000 -and $canCfg.bitrate) { $Bitrate = $canCfg.bitrate }

if (-not $Adapter) {
    Exit-WithError -Class 'CAN_ERROR' -Message 'CAN adapter is not configured; set lab/lab.yaml can.adapter (e.g. "PCAN_USBBus1").' -Detail 'Only adapter, channel and bitrate are betrothed by config; payload/structure are backend-enforced.'
}

# NOTE: verbs below follow Agentic HIL's documented surface; confirm against the
# installed version at setup time (Spec §32). Failures surface as CAN_ERROR.
$logFile = Join-Path $repoRoot "artifacts\logs\can-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

switch ($Command) {
    'session-start' {
        $res = Invoke-FwProcess -FilePath $tool -Arguments @('can', 'session_start', '--adapter', $Adapter, '--channel', $Channel, '--bitrate', $Bitrate) -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out -or $res.exit_code -ne 0) {
            Exit-WithError -Class 'CAN_ERROR' -Message 'CAN session_start failed.' -Detail ($res.stdout + $res.stderr)
        }
    }
    'send' {
        if (-not $ArbitrationId) { Exit-WithError -Class 'CONFIG_ERROR' -Message 'send requires --arbitration-id (e.g. 0x123)' }
        $res = Invoke-FwProcess -FilePath $tool -Arguments @('can', 'send', '--id', $ArbitrationId, '--data', $Data, '--count', $FrameCount) -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out -or $res.exit_code -ne 0) {
            Exit-WithError -Class 'CAN_ERROR' -Message 'CAN send failed.' -Detail ($res.stdout + $res.stderr)
        }
    }
    'read' {
        $res = Invoke-FwProcess -FilePath $tool -Arguments @('can', 'read', '--duration-ms', $DurationMs) -WorkingDirectory $repoRoot -TimeoutMs 60000 -StdoutFile $logFile
        if ($res.timed_out -or $res.exit_code -ne 0) {
            Exit-WithError -Class 'CAN_ERROR' -Message 'CAN read failed.' -Detail ($res.stdout + $res.stderr)
        }
    }
    'filter' {
        if (-not $ArbitrationId) { Exit-WithError -Class 'CONFIG_ERROR' -Message 'filter requires --arbitration-id' }
        $res = Invoke-FwProcess -FilePath $tool -Arguments @('can', 'filter', '--id', $ArbitrationId) -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out -or $res.exit_code -ne 0) {
            Exit-WithError -Class 'CAN_ERROR' -Message 'CAN filter failed.' -Detail ($res.stdout + $res.stderr)
        }
    }
    'session-stop' {
        $res = Invoke-FwProcess -FilePath $tool -Arguments @('can', 'session_stop') -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out -or $res.exit_code -ne 0) {
            Exit-WithError -Class 'CAN_ERROR' -Message 'CAN session_stop failed.' -Detail ($res.stdout + $res.stderr)
        }
    }
}

$result = [ordered]@{
    schema      = 'firmware-can-result/v1'
    ok          = $true
    command     = $Command
    backend     = $Backend
    adapter     = $Adapter
    channel     = $Channel
    bitrate     = $Bitrate
    log         = (Resolve-Path -LiteralPath $logFile).Path
    generated_at = Get-FwTimestamp
}
if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
exit 0