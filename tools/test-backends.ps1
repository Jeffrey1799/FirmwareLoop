<#
.SYNOPSIS
    Backend command tests (Spec GAP-002). Verifies:
      - command construction for all 7 backends (dry-run)
      - execution + log capture through fake executables (keil/iar/west/idf.py)
      - artifact detection failure is reported (no fabricated artifacts)
    Runs in CI without Keil/IAR licenses (Spec §27: fake executable).

    Usage: .\tools\test-backends.ps1 -Json
#>
[CmdletBinding()]
param([switch]$Json)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$fake = Join-Path $repoRoot 'tests\backend\fake-build-tools'
$results = [System.Collections.Generic.List[object]]::new()

function Assert {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $results.Add([pscustomobject]@{ name = $Name; ok = $Ok; detail = $Detail })
    if (-not $Ok) { Write-Warning "FAIL: $Name - $Detail" }
}

function Invoke-Build {
    param([string[]]$ToolArgs)
    $argsList = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'build.ps1')) + $ToolArgs
    return Invoke-FwProcess -FilePath 'pwsh' -Arguments $argsList `
        -WorkingDirectory $repoRoot -TimeoutMs 120000
}

# ---- 1. dry-run command construction (all backends) ---------------------------
$cases = @(
    @{ name = 'cmake';        args = @('-Backend', 'cmake', '-SourceDir', 'demo-firmware', '-DryRun', '-Json') ; expect = 'cmake -S' },
    @{ name = 'make';         args = @('-Backend', 'make', '-SourceDir', 'demo-make', '-DryRun', '-Json')      ; expect = 'make -C' },
    @{ name = 'platformio';   args = @('-Backend', 'platformio', '-SourceDir', 'demo-firmware', '-DryRun', '-Json') ; expect = 'pio run' },
    @{ name = 'keil';         args = @('-Backend', 'keil', '-SourceDir', 'tests/backend/fixtures/keil-proj', '-DryRun', '-Json') ; expect = 'UV4 -b' },
    @{ name = 'iar';          args = @('-Backend', 'iar', '-SourceDir', 'tests/backend/fixtures/iar-proj', '-DryRun', '-Json') ; expect = 'IarBuild' },
    @{ name = 'zephyr';       args = @('-Backend', 'zephyr', '-DryRun', '-Json') ; expect = 'west build' },
    @{ name = 'esp-idf';      args = @('-Backend', 'esp-idf', '-DryRun', '-Json') ; expect = 'idf.py build' }
)

# zephyr needs ZEPHYR_BOARD only for construction
$env:ZEPHYR_BOARD = 'native_sim'

foreach ($c in $cases) {
    $r = Invoke-Build -ToolArgs $c.args
    $jsonLine = ($r.stdout -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
    $ok = $false
    $detail = $r.stderr
    if ($jsonLine) {
        try { $j = $jsonLine | ConvertFrom-Json } catch { $j = $null }
        if ($j -and $j.ok -and $j.dry_run -and $j.command -like "*$($c.expect)*") {
            $ok = $true
            $detail = "command: $($j.command)"
        } else {
            $detail = "unexpected: $jsonLine"
        }
    }
    Assert -Name "construct.$($c.name)" -Ok $ok -Detail $detail
}

# ---- 2. fake executable execution (keil / iar / west / esp-idf) ----------------
$execCases = @(
    @{ name = 'keil';  args = @('-Backend', 'keil', '-SourceDir', 'tests/backend/fixtures/keil-proj', '-BackendTool', (Join-Path $fake 'UV4.cmd'), '-Json') },
    @{ name = 'iar';   args = @('-Backend', 'iar', '-SourceDir', 'tests/backend/fixtures/iar-proj', '-BackendTool', (Join-Path $fake 'IarBuild.cmd'), '-Json') },
    @{ name = 'zephyr'; args = @('-Backend', 'zephyr', '-BackendTool', (Join-Path $fake 'west.cmd'), '-Json') },
    @{ name = 'esp-idf'; args = @('-Backend', 'esp-idf', '-BackendTool', (Join-Path $fake 'idf.py.cmd'), '-Json') }
)
foreach ($c in $execCases) {
    $r = Invoke-Build -ToolArgs $c.args
    $log = Get-Content -LiteralPath (Join-Path $repoRoot 'artifacts\logs\build.log') -Raw -ErrorAction SilentlyContinue
    # fake tool ran (log captured) AND artifact absence was detected honestly
    $ran = $log -match 'FAKE_BACKEND_OK'
    $honest = $r.exit_code -eq 2 -and $r.stdout -match 'ARTIFACT_NOT_FOUND'
    Assert -Name "execute.$($c.name)" -Ok ($ran -and $honest) -Detail "ran=$ran honest=$honest exit=$($r.exit_code) log_tail=$($log.Substring(0,[Math]::Min(120,$log.Length)))"
}

# ---- 3. cmake real build still green -------------------------------------------
$r = Invoke-Build -ToolArgs @('-Configuration', 'Debug', '-Clean', '-Json')
$jsonLine = ($r.stdout -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
$j = $jsonLine | ConvertFrom-Json
Assert -Name 'real.cmake' -Ok ($r.exit_code -eq 0 -and $j.ok -and $j.artifacts.primary.path -like '*firmware.elf*') `
    -Detail "exit=$($r.exit_code) artifact=$($j.artifacts.primary.path)"

# ---- summary -------------------------------------------------------------------
$failed = @($results | Where-Object { -not $_.ok }).Count
$summary = [ordered]@{
    schema     = 'backend-test-result/v1'
    ok         = ($failed -eq 0)
    total      = $results.Count
    failed     = $failed
    tests      = @($results)
    generated_at = Get-FwTimestamp
}
if ($Json) { Write-FwJson ([pscustomobject]$summary) -Compact } else { Write-FwJson ([pscustomobject]$summary) }
exit $(if ($failed -eq 0) { 0 } else { 1 })