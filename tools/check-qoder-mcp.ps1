<#
.SYNOPSIS
    Qoder MCP readiness check (GAP-010, release-fix #6).

    Checks whether the machine is READY to use Agentic HIL inside Qoder, and
    prints the exact registration command when it is not yet registered.
    This is a CHECK-ONLY script: it never modifies Qoder or Agentic HIL
    configuration. (Formerly configure-qoder.ps1; renamed because it does not
    actually register - registration belongs to Qoder local/user scope.)

        detect  -> locate agentic-hil (user-level install preferred, per Agentic
                   HIL official quickstart) + qoder/qodercli CLI
        verify  -> agentic-hil mcp-stdio boots (warmup window)
        advise  -> exact registration command when missing

    Usage:
        .\tools\check-qoder-mcp.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

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

$report = [ordered]@{ schema = 'qoder-mcp-check/v1'; steps = [ordered]@{} }

# ---- 1. detect ------------------------------------------------------------------
# Agentic HIL quickstart recommends a persistent USER-LEVEL installation, not
# one venv per repo. Prefer PATH (user-level), fall back to the repo venv.
$ahil = $null
$g = Get-Command agentic-hil -ErrorAction SilentlyContinue
if ($g) { $ahil = $g.Source }
$ahilSource = 'user-level (PATH)'
if (-not $ahil) {
    $venvAhil = Join-Path $repoRoot '.venv\Scripts\agentic-hil.exe'
    if (Test-Path -LiteralPath $venvAhil) {
        $ahil = $venvAhil
        $ahilSource = 'repo .venv (consider a user-level install: agentic-hil agent-install)'
    }
}
if (-not $ahil -or -not (Test-Path -LiteralPath $ahil)) {
    Exit-WithError -Class 'PROBE_NOT_FOUND' -Message 'agentic-hil not found; install it user-level (uv tool install agentic-hil / pipx) or into .venv (uv pip install agentic-hil).'
}
$report.steps.detect = [ordered]@{ ok = $true; agentic_hil = (Resolve-Path -LiteralPath $ahil).Path; source = $ahilSource }

# qoder CLI: try both spellings seen in the wild (release-fix #6: discovery,
# never hardcode one command name)
$qoderCmd = $null
foreach ($name in @('qoder', 'qodercli')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { $qoderCmd = $c; break }
}
$report.steps.detect.qoder = if ($qoderCmd) { $qoderCmd.Source } else { $null }
$report.steps.detect.qoder_candidate = if ($qoderCmd) { $qoderCmd.Name } else { $null }

# ---- 2. verify MCP server boots ---------------------------------------------------
$proc = $null
$serverOk = $false
try {
    $proc = [System.Diagnostics.Process]::new()
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ahil
    $psi.ArgumentList.Add('mcp-stdio')
    $psi.WorkingDirectory = $repoRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc.StartInfo = $psi
    if ($proc.Start()) {
        Start-Sleep -Milliseconds 1500
        $serverOk = -not $proc.HasExited
    }
} catch {
    $serverOk = $false
} finally {
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch { } }
}
$report.steps.verify = [ordered]@{
    ok = $serverOk
    mcp_handshake = if ($serverOk) { 'agentic-hil mcp-stdio booted and stayed alive (full handshake runs inside Qoder)' } else { 'mcp-stdio exited during warmup - check the installation' }
}

# ---- 3. advise ---------------------------------------------------------------------
$advice = [ordered]@{ ok = $true; registered = $null; command = $null }
if (-not $qoderCmd) {
    $advice.ok = $false
    $advice.note = 'no qoder/qodercli CLI on PATH; register manually in Qoder UI (local/user scope).'
} else {
    # runtime discovery of the mcp subcommand (Spec §32)
    $help = Invoke-FwProcess -FilePath $qoderCmd.Source -Arguments @('mcp', '--help') -WorkingDirectory $repoRoot -TimeoutMs 30000
    if ($help.exit_code -eq 0) {
        $advice.command = "$($qoderCmd.Name) mcp add agentic-hil -- $ahil mcp-stdio"
        $advice.note = 'registration command (run in Qoder local/user scope):'
    } else {
        $advice.ok = $false
        $advice.note = "$($qoderCmd.Name) CLI found but no 'mcp' subcommand; register manually in Qoder UI (local/user scope)."
    }
}
$report.steps.advise = $advice

if ($Json) { Write-FwJson ([pscustomobject]$report) -Compact } else { Write-FwJson ([pscustomobject]$report) }
exit $(if ($report.steps.detect.ok -and $report.steps.verify.ok -and $advice.ok) { 0 } else { 1 })