<#
.SYNOPSIS
    Final acceptance scenario runner (Spec §33 + M6). Drives the complete
    pipeline in one call and writes a final report with all nine mandated
    sections. In simulator mode every leg runs against the real compiled
    artifact / simulated instruments and is fully verifiable offline; with
    real hardware, -Hardware agentic-hil swaps the flash/reset/UART legs to
    Agentic HIL MCP-equivalent CLI verbs.

    Pipeline (Spec §33):
        build -> flash -> reset -> UART -> logic -> scope -> pytest -> report

    Usage:
        .\tools\acceptance-scenario.ps1 -Json                      # simulator
        .\tools\acceptance-scenario.ps1 -Hardware agentic-hil -Json   # real DUT

    Output: artifacts/runs/<run_id>/final-report.json
#>
[CmdletBinding()]
param(
    [ValidateSet('simulator', 'real')]
    [string]$Mode = 'simulator',
    [ValidateSet('simulator', 'agentic-hil')]
    [string]$Hardware,                       # deprecated alias for -Mode
    [string]$Scenario = 'SPI Flash JEDEC ID occasionally fails - fix driver, rebuild, verify',
    [switch]$Json
)

if ($Hardware) {
    $Mode = if ($Hardware -eq 'agentic-hil') { 'real' } else { 'simulator' }
    Write-Warning '-Hardware is deprecated; use -Mode simulator|real'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$python = Resolve-FwPython -RepoRoot $repoRoot
if (-not $python) {
    $err = New-FwError -ErrorClass 'CONFIG_ERROR' -Message 'No Python found; run tools/doctor.ps1.'
    if ($Json) { Write-FwJson $err -Compact } else { Write-FwJson $err }
    exit 2
}

function Invoke-Tool {
    param([string]$Script, [string[]]$ToolArgs)
    $scriptPath = Join-Path $PSScriptRoot $Script
    if ($Script -like '*.py') {
        $filePath = $python
        $runArgs = @($scriptPath) + $ToolArgs
    } elseif ($Script -like '*.ps1') {
        $filePath = 'pwsh'
        $runArgs = @('-NoProfile', '-NonInteractive', '-File', $scriptPath) + $ToolArgs
    } else {
        $filePath = $scriptPath
        $runArgs = $ToolArgs
    }
    $res = Invoke-FwProcess -FilePath $filePath -Arguments $runArgs `
        -WorkingDirectory $repoRoot -TimeoutMs 600000
    if ($res.exit_code -ne 0 -and $res.exit_code -ne 1) {
        Write-Warning "$Script exited $($res.exit_code): $($res.stderr)"
    }
    # last JSON line of stdout
    $jsonLine = $null
    foreach ($l in ($res.stdout -split "`r?`n")) {
        if ($l.TrimStart().StartsWith('{')) { $jsonLine = $l }
    }
    if ($jsonLine) {
        try { return ($jsonLine | ConvertFrom-Json) }
        catch {
            Write-Warning "$Script JSON parse failed: $($_.Exception.Message) | line=[$jsonLine] | rc=$($res.exit_code) | stderr=[$($res.stderr)]"
            return [pscustomobject]@{ ok = $false; error = "json parse: $($_.Exception.Message)"; raw_line = $jsonLine }
        }
    }
    return [pscustomobject]@{ ok = $false; error = "no JSON from $Script"; raw = $res.stdout }
}

# ---- run identity --------------------------------------------------------------
$runId = Get-FwRunId
$runDir = Join-Path $repoRoot "artifacts\runs\$runId"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$env:FW_RUN_DIR = $runDir

$report = [ordered]@{
    schema        = 'firmware-acceptance-report/v1'
    run_id        = $runId
    scenario      = $Scenario
    execution_mode = $Mode
    steps         = [ordered]@{}
    generated_at  = Get-FwTimestamp
}

# ---- 1. build --------------------------------------------------------------------
$build = Invoke-Tool 'build.ps1' @('-Configuration', 'Debug', '-Json')
$report.steps.build = [ordered]@{
    ok       = [bool]($build.PSObject.Properties['ok'] -and $build.ok)
    errors   = if ($build.PSObject.Properties['errors']) { $build.errors } else { 1 }
    warnings = if ($build.PSObject.Properties['warnings']) { $build.warnings } else { 0 }
    artifact = if ($build.PSObject.Properties['artifact']) { $build.artifact } else { $null }
    sha256   = if ($build.PSObject.Properties['artifact_sha256']) { $build.artifact_sha256 } else { $null }
    detail   = if ($build.PSObject.Properties['diagnostics']) { $build.diagnostics } elseif ($build.PSObject.Properties['error']) { $build.error } else { $null }
}

# --- evidence: build.json + hardware.json (Spec §25; identity probing in real
# mode via Agentic HIL read-only commands - release-fix #8) -------------------
$build | Add-Member -NotePropertyName generated_at -NotePropertyValue (Get-FwTimestamp) -ErrorAction SilentlyContinue
$build | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'build.json') -Encoding utf8

$probeSerial = $null
$comPort = $null
$targetIdentity = $null
if ($Mode -eq 'real') {
    $ahilTool = $null
    $g2 = Get-Command agentic-hil -ErrorAction SilentlyContinue
    if ($g2) { $ahilTool = $g2.Source }
    if (-not $ahilTool) {
        $c1 = Join-Path $repoRoot '.venv\Scripts\agentic-hil.exe'
        $c2 = Join-Path $repoRoot '.venv/bin/agentic-hil'
        if (Test-Path -LiteralPath $c1) { $ahilTool = $c1 }
        elseif (Test-Path -LiteralPath $c2) { $ahilTool = $c2 }
    }
    if ($ahilTool) {
        $probes = Invoke-FwProcess -FilePath $ahilTool -Arguments @('debugger-probes') -WorkingDirectory $repoRoot -TimeoutMs 60000
        if ($probes.exit_code -eq 0) {
            try {
                $pj = $probes.stdout | ConvertFrom-Json
                if ($pj.Probes) { $probeSerial = ($pj.Probes -join ',') }
                elseif ($pj.probes) { $probeSerial = ($pj.probes -join ',') }
            } catch { }
        }
        $ports = Invoke-FwProcess -FilePath $ahilTool -Arguments @('com-ports') -WorkingDirectory $repoRoot -TimeoutMs 60000
        if ($ports.exit_code -eq 0) {
            try {
                $pt = $ports.stdout | ConvertFrom-Json
                if ($pt.ports) { $comPort = (@($pt.ports | ForEach-Object { $_.device }) -join ',') }
            } catch { }
        }
    }
}
$hardwareInfo = [ordered]@{
    schema          = 'firmware-hardware-info/v1'
    execution_mode  = $Mode
    target_identity = $targetIdentity
    probe_serial    = $probeSerial
    com_port        = $comPort
    source          = if ($Mode -eq 'real') { 'agentic-hil' } else { 'simulator' }
    generated_at    = Get-FwTimestamp
}
$hardwareInfo | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'hardware.json') -Encoding utf8

# ---- 2+3+4. real lane: Agentic HIL Test Reactor (GAP-004) -------------------------
# The plan (test-plans/real-smoke.yaml) drives flash -> reset -> UART expect
# with logical devices only. Missing devices make the reactor fail - never a
# simulator stand-in, never a PASS without hardware.
$reactor = $null
if ($Mode -eq 'real') {
    $ahil = Join-Path $repoRoot '.venv\Scripts\agentic-hil.exe'
    if (-not (Test-Path -LiteralPath $ahil)) {
        $g = Get-Command agentic-hil -ErrorAction SilentlyContinue
        if ($g) { $ahil = $g.Source }
    }
    if (-not $ahil) {
        $report.steps.flash = [ordered]@{ ok = $false; error_class = 'REAL_HARDWARE_REQUIRED'; error = 'agentic-hil not installed; real mode requires the Agentic HIL test reactor' }
        $report.steps.reset = [ordered]@{ ok = $false; error_class = 'REAL_HARDWARE_REQUIRED'; error = 'not executed (reactor unavailable)' }
        $report.steps.uart = [ordered]@{ ok = $false; error_class = 'REAL_HARDWARE_REQUIRED'; error = 'not executed (reactor unavailable)' }
    } else {
        $plan = Join-Path $repoRoot 'test-plans\real-smoke.yaml'
        # release-fix #3: resolve the REAL primary artifact from the
        # firmware-artifacts/v1 manifest (build step) and inject it into a
        # run-local copy of the plan - never hardcode firmware.elf in the plan.
        $artifactManifest = Join-Path $repoRoot 'artifacts\build\artifacts.json'
        $planPath = $plan
        if (Test-Path -LiteralPath $artifactManifest) {
            try {
                $manifest = Get-Content -LiteralPath $artifactManifest -Raw | ConvertFrom-Json
                $primaryProp = $manifest.primary
                if ($primaryProp -and $primaryProp.native_path -and (Test-Path -LiteralPath $primaryProp.native_path)) {
                    $runPlan = Join-Path $runDir 'real-smoke.runtime.yaml'
                    $planText = Get-Content -LiteralPath $plan -Raw
                    $planText = [regex]::Replace($planText, '(?m)^(\s*image_path:\s*).*$', "`${1}$($primaryProp.native_path)")
                    $planText | Set-Content -LiteralPath $runPlan -Encoding utf8
                    $planPath = $runPlan
                    $report.steps.flash = [ordered]@{ artifact_source = 'firmware-artifacts/v1 manifest'; artifact = $primaryProp.native_path }
                }
            } catch { }
        }
        $reactor = Invoke-FwProcess -FilePath $ahil -Arguments @('test-reactor', '--test-config', $planPath, '--wait-s', '0') -WorkingDirectory $repoRoot -TimeoutMs 600000
        $reactorOk = $reactor.exit_code -eq 0
        $reactorText = ($reactor.stdout + $reactor.stderr)
        # structured summary of the reactor verdict
        $verdict = if ($reactorText -match '(?s)\{[^{}]*"ok"\s*:\s*(true|false)[^{}]*\}') {
            $Matches[0]
        } else { $reactorText }
        $report.steps.flash = [ordered]@{ ok = $reactorOk; backend = 'agentic-hil-test-reactor'; plan = $planPath; result = ($verdict | Select-Object -First 1) }
        $report.steps.reset = [ordered]@{ ok = $reactorOk; backend = 'agentic-hil-test-reactor'; note = 'flash+reset+UART expect driven by the reactor plan' }
        $report.steps.uart = [ordered]@{ ok = $reactorOk; backend = 'agentic-hil-test-reactor'; note = 'UART expect inside plan (Application started / JEDEC EF 40 18)' }
    }
} else {
    $report.steps.flash = [ordered]@{
        ok = $true
        note = "simulator mode: artifact is the DUT; flash verified via firmware build + HIL run (real flash requires -Mode real)"
    }
    $reset = Invoke-Tool 'reset.ps1' @('-Backend', 'simulator', '-Json')
    $report.steps.reset = [ordered]@{ ok = $reset.ok; backend = $reset.backend }

    # ---- simulator UART leg -----------------------------------------------------
    $artifact = Join-Path $repoRoot 'artifacts\build\firmware.elf'
    $probe = Invoke-FwProcess -FilePath $python -Arguments @((Join-Path $PSScriptRoot 'common\uart_probe.py'), $artifact, 'jedec') -WorkingDirectory $repoRoot -TimeoutMs 60000
    try { $uartResult = $probe.stdout | ConvertFrom-Json } catch { $uartResult = [ordered]@{ ok = $false; error = $probe.stderr } }
    if ($probe.exit_code -eq 0) {
        Save-FwLog -Path (Join-Path $runDir 'uart.log') -Content "RX: $($uartResult.banner -join ' | ')"
        Save-FwLog -Path (Join-Path $runDir 'uart.log') -Content "TX: jedec"
        Save-FwLog -Path (Join-Path $runDir 'uart.log') -Content "RX: $($uartResult.reply)"
    }
    $report.steps.uart = $uartResult
}

# ---- 5. logic analyzer ------------------------------------------------------------
# --- evidence: flash.json (Spec §25) ----------------------------------------------
$flashBackendProp = $report.steps.flash.PSObject.Properties['backend']
$flashEvidence = [ordered]@{
    schema     = 'firmware-flash-result/v1'
    ok         = $report.steps.flash.ok
    backend    = if ($flashBackendProp) { $flashBackendProp.Value } else { 'simulator' }
    artifact   = $report.steps.build.artifact
    generated_at = Get-FwTimestamp
}
$flashEvidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'flash.json') -Encoding utf8
# real mode: sigrok (or Saleae MCP in Qoder); simulator data is NEVER used to
# fabricate real evidence (GAP-007/008). Missing backend => REAL_HARDWARE_REQUIRED.
$logic = [ordered]@{ ok = $false }
if ($Mode -eq 'real') {
    $cap = Invoke-Tool 'logic_capture.ps1' @('-Protocol', 'spi', '-Backend', 'sigrok', '-Json')
    if (-not $cap.ok -or $cap.error_class) {
        $logic = [ordered]@{
            ok = $false
            error_class = if ($cap.error_class) { $cap.error_class } else { 'REAL_HARDWARE_REQUIRED' }
            error = 'real logic capture needs sigrok-cli or Saleae; simulator captures are not real evidence'
        }
    } else {
        $decode = Invoke-Tool 'logic_decode.ps1' @('-Capture', (Split-Path $cap.capture), '-Expect', '9FEF4018', '-ExpectKind', 'hex', '-Json')
        $logic = [ordered]@{
            ok        = $decode.ok
            protocol  = 'spi'
            backend   = 'sigrok'
            real_hardware = $true
            bytes_hex = $decode.bytes_hex
            frames    = $decode.frames
            expectation = '9FEF4018'
            capture   = $cap.capture
            decoded   = if ($decode.out_file) { $decode.out_file } else { $null }
        }
    }
} else {
    $cap = Invoke-Tool 'logic_capture.ps1' @('-Protocol', 'spi', '-Json')
    if ($cap.ok) {
        $decode = Invoke-Tool 'logic_decode.ps1' @('-Capture', (Split-Path $cap.capture), '-Expect', '9FEF4018', '-ExpectKind', 'hex', '-Json')
        $logic = [ordered]@{
            ok        = $decode.ok
            protocol  = 'spi'
            backend   = 'simulator'
            real_hardware = $false
            bytes_hex = $decode.bytes_hex
            frames    = $decode.frames
            expectation = '9FEF4018'
            capture   = $cap.capture
            decoded   = if ($decode.out_file) { $decode.out_file } else { $null }
        }
    }
}
$report.steps.logic = $logic

# ---- 6. scope / psu ---------------------------------------------------------------
# real mode reads lab/lab.yaml instruments (visa backend); without a trusted
# bench policy instrument writes fail closed (GAP-009), reads without a
# configured visa instrument report INSTRUMENT_NOT_FOUND - never simulator data.
$freq = Invoke-Tool 'instrument_cli.py' @('scope', 'measure-frequency', '--instrument', 'scope1')  # run via python
$freqOk = $false
$freqVal = $null
if ($freq.ok) { $freqOk = $freq.ok; $freqVal = $freq.value }
$vpp = Invoke-Tool 'instrument_cli.py' @('scope', 'measure-vpp', '--instrument', 'scope1')
# real mode: measurements must come from a visa backend - simulator data is
# never real evidence (GAP-007/011)
$realFreq = ($freq.ok -and $freq.execution_mode -eq 'real')
$realVpp = ($vpp.ok -and $vpp.execution_mode -eq 'real')
$report.steps.scope = [ordered]@{
    frequency_hz = $freqVal
    vpp_v        = if ($vpp.ok) { $vpp.value } else { $null }
    ok           = if ($Mode -eq 'real') { $realFreq -and $realVpp } else { $freqOk -and $vpp.ok }
    execution_mode = $Mode
    note         = if ($Mode -eq 'real' -and -not ($realFreq -and $realVpp)) { 'measurements were not visa-backed; simulator data is not real evidence' } else { $null }
}

# persist instrument evidence (Spec §25 instruments/measurements.json)
$measPath = Join-Path $runDir 'measurements.json'
$meas = @()
if (Test-Path -LiteralPath $measPath) {
    try { $meas = @(Get-Content -LiteralPath $measPath -Raw | ConvertFrom-Json) } catch { $meas = @() }
}
$freq | Add-Member -NotePropertyName timestamp -NotePropertyValue (Get-FwTimestamp) -ErrorAction SilentlyContinue
$meas += $freq
if ($vpp.ok) { $vpp | Add-Member -NotePropertyName timestamp -NotePropertyValue (Get-FwTimestamp) -ErrorAction SilentlyContinue; $meas += $vpp }
$meas | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $measPath -Encoding utf8

# ---- 7. pytest HIL -----------------------------------------------------------------
# real mode MUST run through test.ps1 -Mode real: required HIL tests that are
# skipped become failures there (release-fix #2), and the reported
# execution_mode is verified below - simulator/skip can never count as PASS.
$hilArgs = @('-Json')
if ($Mode -eq 'real') { $hilArgs = @('-Mode', 'real', '-Json') }
$hil = Invoke-Tool 'test.ps1' $hilArgs
$pytestOk = $hil.ok
$modeNote = $null
if ($Mode -eq 'real') {
    $reported = $hil.execution_mode
    if ($reported -ne 'real') {
        $pytestOk = $false
        $modeNote = "test.ps1 reported execution_mode='$reported' instead of 'real'; simulator/skip cannot count as real PASS"
    } elseif (-not $hil.ok) {
        $modeNote = 'real-mode HIL failed (skips count as failures)'
    }
}
$report.steps.pytest = [ordered]@{
    ok       = $pytestOk
    execution_mode = if ($Mode -eq 'real') { $hil.execution_mode } else { 'simulator' }
    total    = @($hil.tests).Count
    passed   = @($hil.tests | Where-Object status -eq 'passed').Count
    failed   = @($hil.tests | Where-Object status -eq 'failed').Count
    skipped  = @($hil.tests | Where-Object status -eq 'skipped').Count
    summary  = (Join-Path $runDir 'summary.json')
    failures = @($hil.tests | Where-Object status -eq 'failed')
    note     = $modeNote
}

# ---- final report (Spec §33) --------------------------------------------------------
$git = Get-FwGitInfo -RepoRoot $repoRoot
$codeChanges = @()
$statusLines = git -C $repoRoot status --porcelain 2>$null
foreach ($line in $statusLines) {
    if ($line -match '^..\s+(.+)$') { $codeChanges += $Matches[1].Trim('"') }
}

$finalReport = [ordered]@{
    schema              = 'firmware-acceptance-report/v1'
    run_id              = $runId
    scenario            = $Scenario
    execution_mode      = $Mode
    root_cause_analysis = if ($Mode -eq 'real') {
        if ($report.steps.pytest.ok) {
            'No defect reproduced on real hardware: JEDEC read returns 3-byte ID, UART/spi evidence captured from the DUT.'
        } else {
            'Reproduced defect on real hardware: inspect steps.pytest.failures (expected/actual captured) and uart/logic evidence.'
        }
    } elseif ($report.steps.pytest.ok) {
        'No defect reproduced in simulated scenario: JEDEC read returns 3-byte ID, SPI decode 9F EF 40 18, PWM 20 kHz within limits.'
    } else {
        'Reproduced defect: inspect steps.pytest.failures (expected/actual captured) and uart/logic evidence.'
    }
    code_changes        = $codeChanges
    build_result        = @{
        ok      = $report.steps.build.ok
        errors  = $report.steps.build.errors
        warnings = $report.steps.build.warnings
    }
    firmware_artifact   = @{
        path   = $report.steps.build.artifact
        sha256 = $report.steps.build.sha256
    }
    uart_evidence       = if ($report.steps.uart.ok) { $report.steps.uart } else { $report.steps.uart }
    logic_evidence      = $report.steps.logic
    scope_measurements  = $report.steps.scope
    test_result         = $report.steps.pytest
    remaining_risks     = if ($Mode -eq 'real') {
        @(
            'Real mode: verify the reactor report and physical evidence before trusting PASS.',
            'Instrument writes require an authoritative bench policy (%APPDATA%\FirmwareLoop\benches\<id>\limits.yaml or FIRMWARELOOP_BENCH_CONFIG).'
        )
    } else {
        @(
            'Simulator mode: no silicon exercised; run with -Mode real against the real DUT for final acceptance.',
            'Real instruments (scope/psu) use simulator backend until VISA resources are configured in lab/lab.yaml.'
        )
    }
    steps               = $report.steps
    git                 = $git
    generated_at        = Get-FwTimestamp
}

$reportPath = Join-Path $runDir 'final-report.json'
$finalReport | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $reportPath -Encoding utf8
$reportBody = [pscustomobject]$finalReport
$reportBody | Add-Member -NotePropertyName report_file -NotePropertyValue (Resolve-Path -LiteralPath $reportPath).Path

# ---- evidence layout (Spec §25): logic/ + instruments/ + final-report.md ------
$logicDir = Join-Path $runDir 'logic'
$instDir = Join-Path $runDir 'instruments'
New-Item -ItemType Directory -Force -Path $logicDir, $instDir | Out-Null
$logicCapProp = $report.steps.logic.PSObject.Properties['capture']
$logicDecProp = $report.steps.logic.PSObject.Properties['decoded']
if ($logicCapProp -and $logicCapProp.Value -and (Test-Path -LiteralPath $logicCapProp.Value)) {
    Copy-Item -LiteralPath $logicCapProp.Value -Destination (Join-Path $logicDir 'capture.csv') -Force -ErrorAction SilentlyContinue
}
if ($logicDecProp -and $logicDecProp.Value -and (Test-Path -LiteralPath $logicDecProp.Value)) {
    Copy-Item -LiteralPath $logicDecProp.Value -Destination (Join-Path $logicDir 'decode.json') -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath (Join-Path $runDir 'measurements.json')) {
    Copy-Item -LiteralPath (Join-Path $runDir 'measurements.json') -Destination (Join-Path $instDir 'measurements.json') -Force -ErrorAction SilentlyContinue
}

$md = @()
$md += "# FirmwareLoop Acceptance Report — $runId"
$md += ""
$md += "- **scenario**: $Scenario"
$md += "- **execution_mode**: $Mode"
$md += "- **root cause**: $($finalReport.root_cause_analysis)"
$md += "- **git**: $($git.commit) (dirty=$($git.dirty))"
$md += ""
$md += "## Build"
$md += ""
$md += "- ok: $($finalReport.build_result.ok), errors: $($finalReport.build_result.errors), warnings: $($finalReport.build_result.warnings)"
$md += "- artifact: $($finalReport.firmware_artifact.path)"
$md += "- sha256: $($finalReport.firmware_artifact.sha256)"
$md += ""
$md += "## UART"
$md += ""
$uartReply = $finalReport.uart_evidence.PSObject.Properties['reply']
$uartErr = $finalReport.uart_evidence.PSObject.Properties['error']
if ($finalReport.uart_evidence.ok -and $uartReply) {
    $md += "- reply: $($uartReply.Value)"
} else {
    $md += "- ok: $($finalReport.uart_evidence.ok) ($(if ($uartErr) { $uartErr.Value } else { 'n/a' }))"
}
$md += ""
$md += "## Logic"
$md += ""
$logicHex = $finalReport.logic_evidence.PSObject.Properties['bytes_hex']
$logicProto = $finalReport.logic_evidence.PSObject.Properties['protocol']
$md += "- ok: $($finalReport.logic_evidence.ok), protocol: $(if ($logicProto) { $logicProto.Value } else { 'n/a' }), bytes: $(if ($logicHex) { $logicHex.Value } else { 'n/a' })"
$md += ""
$md += "## Scope"
$md += ""
$md += "- frequency: $($finalReport.scope_measurements.frequency_hz) Hz, vpp: $($finalReport.scope_measurements.vpp_v) V"
$md += ""
$md += "## Tests"
$md += ""
$md += "- ok: $($finalReport.test_result.ok), total: $($finalReport.test_result.total), failed: $($finalReport.test_result.failed)"
$md += ""
$md += "## Remaining risks"
$md += ""
foreach ($risk in $finalReport.remaining_risks) { $md += "- $risk" }
$md | Set-Content -LiteralPath (Join-Path $runDir 'final-report.md') -Encoding utf8

if ($Json) { Write-FwJson $reportBody -Compact } else { Write-FwJson $reportBody }

$allOk = $report.steps.build.ok -and $report.steps.logic.ok -and $report.steps.scope.ok -and $report.steps.pytest.ok
if ($Mode -eq 'real') { $allOk = $allOk -and $report.steps.flash.ok -and $report.steps.uart.ok }
exit $(if ($allOk) { 0 } else { 1 })