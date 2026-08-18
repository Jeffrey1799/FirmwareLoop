<#
.SYNOPSIS
    Environment doctor (Spec M0 / §26). Checks the pieces of the baseline
    toolchain and returns one JSON document:

        .\tools\doctor.ps1 -Json

    The doctor NEVER fails the whole run because hardware is absent: hardware
    categories report status "missing"/"not_configured" and delivery is
    deferred to the project. Only a broken core toolchain (no python, no git,
    no build tool) is reported as not-ok.
#>
[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$python = Resolve-FwPython -RepoRoot $repoRoot
$venvBin = if ($python -and $python -match '.venv[\\/]Scripts[\\/]python.exe$') { Split-Path $python } else { $null }

function Test-Tool {
    param([string]$Name)
    # prefer the project venv bin dir (tools installed without polluting PATH)
    $candidate = if ($venvBin) { Join-Path $venvBin ($Name + '.exe') } else { $null }
    $cmd = if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        Get-Item -LiteralPath $candidate
    } else {
        Get-Command $Name -ErrorAction SilentlyContinue
    }
    if ($cmd) {
        $v = $null
        $src = if ($cmd.GetType().Name -eq 'ApplicationInfo') { $cmd.Source } else { $cmd.FullName }
        try { $v = (& $src --version 2>&1 | Select-Object -First 1) } catch { }
        return [pscustomobject]@{ status = 'ok'; path = $src; version = [string]$v }
    }
    return [pscustomobject]@{ status = 'missing'; path = $null; version = $null }
}

function Test-PyModule {
    param([string]$Module, [string]$Python)
    if (-not $Python) { return [pscustomobject]@{ status = 'missing'; detail = 'no python' } }
    $out = & $Python -c "import $Module; print(getattr($Module, '__version__', 'present'))" 2>&1
    if ($LASTEXITCODE -eq 0) { return [pscustomobject]@{ status = 'ok'; detail = ([string]$out).Trim() } }
    return [pscustomobject]@{ status = 'missing'; detail = ([string]$out).Trim() }
}

$checks = [ordered]@{}

# --- core toolchain -----------------------------------------------------------
$checks.python = if ($python) {
    $pyv = & $python --version 2>&1
    [pscustomobject]@{ status = 'ok'; path = $python; version = ([string]$pyv).Trim() }
} else {
    [pscustomobject]@{ status = 'missing'; path = $null; version = $null }
}

$checks.git = if ((Get-Command git -ErrorAction SilentlyContinue)) {
    $gv = git --version 2>&1
    $gitStatus = [pscustomobject]@{ status = 'ok'; path = (Get-Command git).Source; version = ([string]$gv).Trim() }
    $gitStatus | Add-Member -NotePropertyName repo -NotePropertyValue (git -C $repoRoot rev-parse --is-inside-work-tree 2>$null)
    $gitStatus
} else {
    [pscustomobject]@{ status = 'missing'; path = $null; version = $null }
}

# --- build backends -----------------------------------------------------------
foreach ($tool in @('cmake', 'ninja', 'make', 'gcc', 'clang')) {
    $checks[$tool] = Test-Tool $tool
}
$checks.keil = Test-Tool 'UV4'
$checks.iar = Test-Tool 'IarBuild'
$checks.idf = Test-Tool 'idf.py'
$checks.west = Test-Tool 'west'
$checks.platformio = Test-Tool 'pio'

# --- hardware / lab layer ------------------------------------------------------
$checks.agentic_hil = Test-Tool 'agentic-hil'
$checks.openocd = Test-Tool 'openocd'
$checks.sigrok_cli = Test-Tool 'sigrok-cli'
$checks.pyocd = if ($python) {
    Test-PyModule 'pyocd' $python
} else { [pscustomobject]@{ status = 'missing'; detail = 'no python' } }

$checks.pytest = if ($python) { Test-PyModule 'pytest' $python } else { [pscustomobject]@{ status = 'missing'; detail = 'no python' } }
$checks.pyserial = if ($python) { Test-PyModule 'serial' $python } else { [pscustomobject]@{ status = 'missing'; detail = 'no python' } }
$checks.pyvisa = if ($python) { Test-PyModule 'pyvisa' $python } else { [pscustomobject]@{ status = 'missing'; detail = 'no python' } }

# COM ports present (UART candidates) - informational, never hardcoded.
# Prefer Agentic HIL's enumeration (hardware-aware) when installed, else WMI.
$comPorts = @()
$ahil = if ($venvBin) { Join-Path $venvBin 'agentic-hil.exe' } else { $null }
if ($ahil -and (Test-Path -LiteralPath $ahil)) {
    try {
        $raw = & $ahil com-ports 2>$null | Out-String
        $parsed = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($parsed -and $parsed.ports) {
            $comPorts = @($parsed.ports | ForEach-Object { $_.device } | Where-Object { $_ })
        }
    } catch { }
}
if ($comPorts.Count -eq 0) {
    try {
        $comPorts = @((Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID))
    } catch { }
}
$checks.com_ports = [pscustomobject]@{
    status = if ($comPorts.Count -gt 0) { 'ok' } else { 'none' }
    source = if ($ahil -and (Test-Path -LiteralPath $ahil)) { 'agentic-hil' } else { 'wmi' }
    ports  = $comPorts
}

# Saleae Logic 2 MCP endpoint (127.0.0.1:10530) is optional; check socket
$logicOk = $false
try {
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect('127.0.0.1', 10530)
    $logicOk = $tcp.Connected
    $tcp.Close()
} catch { }
$checks.logic2_mcp = [pscustomobject]@{ status = if ($logicOk) { 'ok' } else { 'not_configured' }; endpoint = 'http://127.0.0.1:10530' }

# --- composition ----------------------------------------------------------------
$coreNames = @('python', 'git', 'cmake')
$coreOk = $true
$missingCore = @()
foreach ($n in $coreNames) {
    if ($checks[$n].status -ne 'ok') { $coreOk = $false; $missingCore += $n }
}

$result = [ordered]@{
    schema       = 'firmware-doctor/v1'
    ok           = $coreOk
    generated_at = Get-FwTimestamp
    host         = [ordered]@{
        os      = [System.Environment]::OSVersion.VersionString
        pwsh    = $PSVersionTable.PSVersion.ToString()
        machine = $env:COMPUTERNAME
    }
    missing_core = $missingCore
    checks       = $checks
}

if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }

exit $(if ($coreOk) { 0 } else { 1 })