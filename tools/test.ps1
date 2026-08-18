<#
.SYNOPSIS
    HIL test runner (Spec §18/19/23). Runs pytest under the project venv,
    produces JUnit XML, a firmware-hil-result/v1 summary and a per-run audit
    directory under artifacts/runs/<run_id>/.

    Usage:
        .\tools\test.ps1 -Json
        .\tools\test.ps1 -TestPath tests/hil -RunId my-run -Json

    Exit codes:
        0  all tests passed (or skipped)
        1  at least one test failed
        2  configuration/runner error
#>
[CmdletBinding()]
param(
    [string]$TestPath = 'tests/hil',
    [string]$RunId,
    [switch]$Json,
    [switch]$NoBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$python = Resolve-FwPython -RepoRoot $repoRoot
if (-not $python) {
    $err = New-FwError -ErrorClass 'CONFIG_ERROR' -Message 'No Python found. Run tools/doctor.ps1.'
    if ($Json) { Write-FwJson $err -Compact } else { Write-FwJson $err; Write-Error $err.error }
    exit 2
}

# --- run identity & audit dir -------------------------------------------------
$runId = if ($RunId) { $RunId } else { Get-FwRunId }
$runsDir = Join-Path $repoRoot "artifacts\runs\$runId"
New-Item -ItemType Directory -Force -Path $runsDir | Out-Null
$env:FW_RUN_DIR = $runsDir

# --- firmware identity --------------------------------------------------------
$artifact = Join-Path $repoRoot 'artifacts\build\firmware.elf'
$firmwareInfo = [ordered]@{
    artifact      = $null
    artifact_sha256 = $null
    git_commit    = $null
}
if (Test-Path -LiteralPath $artifact) {
    $firmwareInfo.artifact = (Resolve-Path -LiteralPath $artifact).Path
    $firmwareInfo.artifact_sha256 = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
}
$git = Get-FwGitInfo -RepoRoot $repoRoot
$firmwareInfo.git_commit = $git.commit

# repo state at run start for the audit trail (Spec §23 modified files)
$modifiedFiles = @()
$statusLines = git -C $repoRoot status --porcelain 2>$null
foreach ($line in $statusLines) {
    if ($line -match '^..\s+(.+)$') {
        $p = $Matches[1].Trim('"')
        if ($p) { $modifiedFiles += $p }
    }
}

# --- run pytest ---------------------------------------------------------------
# Pass --junitxml as a SEPARATE token with a relative path: pytest 9.x on this
# platform mis-parses the "--junitxml=<absolute or relative path>" fused form
# (the value is wrongly treated as a collect argument -> exit 4, "no match").
$xmlRel = (Join-Path 'artifacts\runs' "$runId\pytest.xml").Replace('\', '/')
$xmlNative = Join-Path $repoRoot $xmlRel.Replace('/', '\')
New-Item -ItemType File -Force -Path $xmlNative | Out-Null
$pytestArgs = @('-m', 'pytest', $TestPath, '--junitxml', $xmlRel, '--tb=short', '-p', 'no:cacheprovider', '-rA')
$res = Invoke-FwProcess -FilePath $python -Arguments $pytestArgs -WorkingDirectory $repoRoot -TimeoutMs 900000
Save-FwLog -Path (Join-Path $runsDir 'pytest.stdout.log') -Content $res.stdout
Save-FwLog -Path (Join-Path $runsDir 'pytest.stderr.log') -Content $res.stderr

if ($res.timed_out) {
    $err = New-FwError -ErrorClass 'INSTRUMENT_TIMEOUT' -Message 'pytest run timed out and was killed.' -Detail $xmlReport
    if ($Json) { Write-FwJson $err -Compact } else { Write-FwJson $err; Write-Error $err.error }
    exit 2
}
if ($res.exit_code -eq 4) {
    # usage error: pytest rejected the invocation - configuration problem
    $err = New-FwError -ErrorClass 'CONFIG_ERROR' -Message 'pytest rejected the invocation (usage error, exit 4).' -Detail $res.stdout
    if ($Json) { Write-FwJson $err -Compact } else { Write-FwJson $err; Write-Error $err.error }
    exit 2
}

# --- parse JUnit XML ----------------------------------------------------------
$tests = @()
$failures = 0
if (Test-Path -LiteralPath $xmlNative) {
    [xml]$xml = Get-Content -LiteralPath $xmlNative -Raw
    foreach ($tc in $xml.testsuites.testsuite.testcase) {
        $entry = [ordered]@{
            name     = $tc.name
            status   = 'passed'
            expected = $null
            actual   = $null
            evidence = @()
        }
        $failNode = $tc.SelectSingleNode('failure')
        $skipNode = $tc.SelectSingleNode('skipped')
        if ($failNode) {
            $entry.status = 'failed'
            $failures++
            $msg = [string]$failNode.message
            $expected = $null; $actual = $null
            if ($msg -match 'expected (.+?), actual (.+?)(?::|$)') {
                $expected = $Matches[1]; $actual = $Matches[2]
            }
            if (-not $expected -and $msg -match "expected (.+)") { $expected = $Matches[1] }
            $entry.expected = $expected
            $entry.actual = $actual
            $entry.failure = ([string]$failNode.InnerText)
        } elseif ($skipNode) {
            $entry.status = 'skipped'
            $entry.reason = [string]$skipNode.message
        }
        # evidence artifacts copied into the run dir by fixtures
        $tests += [pscustomobject]$entry
    }
}

# --- evidence inventory -------------------------------------------------------
$evidence = @()
foreach ($f in @('uart.log', 'measurements.json')) {
    $p = Join-Path $runsDir $f
    if (Test-Path -LiteralPath $p) { $evidence += (Resolve-Path -LiteralPath $p).Path }
}

$summary = [ordered]@{
    schema    = 'firmware-hil-result/v1'
    run_id    = $runId
    ok        = ($failures -eq 0)
    firmware  = $firmwareInfo
    tests     = $tests
    evidence  = $evidence
    audit     = [ordered]@{
        git_commit     = $git.commit
        git_dirty      = $git.dirty
        modified_files = $modifiedFiles
        generated_at   = Get-FwTimestamp
    }
    hardware  = [ordered]@{
        target_identity = $null   # set when a real probe is configured (M2)
        probe_serial    = $null
        com_port        = $null
    }
    generated_at = Get-FwTimestamp
}
$summaryPath = Join-Path $runsDir 'summary.json'
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8

if ($Json) { Write-FwJson ([pscustomobject]$summary) -Compact } else { Write-FwJson ([pscustomobject]$summary) }

exit $(if ($failures -eq 0) { 0 } else { 1 })