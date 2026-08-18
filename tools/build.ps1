<#
.SYNOPSIS
    Build adapter (Spec §8, v0.0.2 GAP-002). Dispatches to the project's
    existing build system across seven backends and returns structured
    firmware-build-result/v1 JSON plus a firmware-artifacts/v1 manifest.

    Backends: cmake | make | platformio | keil | iar | zephyr | esp-idf

    Detection precedence (GAP-002):
        1. -Backend (explicit)
        2. project config (lab/lab.yaml -> project.build_backend)
        3. strong project marker (west.yml -> zephyr, sdkconfig/idf.py ->
           esp-idf, platformio.ini, *.uvproj*, *.ewp, Makefile, CMakeLists.txt)
        4. generic detection

    Usage:
        .\tools\build.ps1 -Configuration Debug -Json
        .\tools\build.ps1 -Backend make -SourceDir .\demo-make -Json
        .\tools\build.ps1 -Backend keil -DryRun -Json          # command construction
        .\tools\build.ps1 -Backend keil -BackendTool C:\fake\UV4.cmd -Json

    Exit codes:
        0  build ok (or dry-run construction ok)
        1  build failed (compile/link errors)
        2  configuration/toolchain error
#>
[CmdletBinding()]
param(
    [ValidateSet('cmake', 'make', 'platformio', 'keil', 'iar', 'zephyr', 'esp-idf')]
    [string]$Backend,
    [string]$Configuration = 'Debug',
    [switch]$Json,
    [string]$SourceDir,
    [string]$ArtifactDir,
    [string]$BuildDir,
    [string]$BackendTool,          # override tool path (fake executable in tests)
    [int]$TimeoutMs = 600000,
    [switch]$SkipConfigure,
    [switch]$Clean,
    [switch]$DryRun               # print constructed command, do not execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'common\build-backends.psm1') -Force

$repoRoot = Get-FwRepoRoot
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# ------------------------------------------------------- 1. backend resolution
$projBackend = $null
$labCfgObj = Get-FwLabConfig -RepoRoot $repoRoot
if ($labCfgObj) {
    $projProp = $labCfgObj.PSObject.Properties['project']
    if ($projProp) {
        $bbProp = $projProp.Value.PSObject.Properties['build_backend']
        if ($bbProp) { $projBackend = [string]$bbProp.Value }
    }
}
$detect = Get-FwBackendDetect -ExplicitBackend $Backend -ProjectBackend $projBackend -SourceDir $SourceDir -RepoRoot $repoRoot
$backend = $detect.backend
$src = $detect.src
$projectFile = $detect.project_file
$detectSource = $detect.source

if (-not $backend) {
    Exit-WithError -Class 'CONFIG_ERROR' -Message 'No build system detected (west.yml / sdkconfig / platformio.ini / *.uvproj* / *.ewp / Makefile / CMakeLists.txt). Pass -Backend and/or -SourceDir.' `
        -Detail "project config backend: $projBackend"
}

if (-not $BuildDir) { $BuildDir = Join-Path $repoRoot "artifacts\build\$backend-$Configuration" }
if (-not $ArtifactDir) { $ArtifactDir = Join-Path $repoRoot 'artifacts\build' }
New-Item -ItemType Directory -Force -Path $BuildDir, $ArtifactDir, (Join-Path $repoRoot 'artifacts\logs') | Out-Null
if ($Clean) {
    Remove-Item -Recurse -Force -LiteralPath $BuildDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
}

# ------------------------------------------------------- 2. command construction
$cmd = Get-FwBackendCommand -Backend $backend -Src $src -ProjectFile $projectFile `
    -Configuration $Configuration -BuildDir $BuildDir -Tool $BackendTool `
    -AllowMissingTool:$DryRun

if ($cmd.ContainsKey('missing')) {
    $need = $cmd.missing
    $hint = switch ($need) {
        'cmake' { 'winget install Kitware.CMake' }
        'make'  { 'winget install GnuWin32.Make (or use CI: apt install make)' }
        'platformio' { 'pip install platformio' }
        'keil'  { 'install Keil uVision (UV4.exe must be on PATH)' }
        'iar'   { 'install IAR EWARM (IarBuild.exe must be on PATH)' }
        'zephyr' { 'pip install west && west init' }
        'esp-idf' { 'install ESP-IDF (idf.py must be on PATH)' }
        'keil-project' { 'no .uvproj* found in source dir' }
        'iar-project'  { 'no .ewp found in source dir' }
        'zephyr-board' { $cmd.detail }
        default { "tool '$need' not found" }
    }
    Exit-WithError -Class 'CONFIG_ERROR' -Message "backend '$backend' is unavailable: $need" -Detail $hint
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\build-$stamp.log"
$logCanonical = Join-Path $repoRoot 'artifacts\logs\build.log'

if ($DryRun) {
    $dry = [ordered]@{
        schema        = 'firmware-build-result/v1'
        ok            = $true
        dry_run       = $true
        configuration = $Configuration
        backend       = $backend
        command       = $cmd.label
        command_line  = $cmd.file + ' ' + ($cmd.args -join ' ')
        cwd           = if ($cmd.cwd) { $cmd.cwd } else { $repoRoot }
        artifact      = $null
        warnings      = 0
        errors        = 0
        duration_ms   = 0
        log           = $null
        git           = Get-FwGitInfo -RepoRoot $repoRoot
        generated_at  = Get-FwTimestamp
    }
    if ($Json) { Write-FwJson ([pscustomobject]$dry) -Compact } else { Write-FwJson ([pscustomobject]$dry) }
    exit 0
}

# ------------------------------------------------------- 3. execute
$res = Invoke-FwProcess -FilePath $cmd.file -Arguments $cmd.args `
    -WorkingDirectory $(if ($cmd.cwd) { $cmd.cwd } else { $repoRoot }) `
    -TimeoutMs $TimeoutMs -StdoutFile $logFile
# follow-up steps (e.g. cmake --build after configure)
$hasSteps = ($cmd -is [hashtable]) -and $cmd.ContainsKey('steps')
if ($res.exit_code -eq 0 -and $hasSteps) {
    foreach ($step in $cmd.steps) {
        $stepRes = Invoke-FwProcess -FilePath $step.file -Arguments $step.args `
            -WorkingDirectory $(if ($step.cwd) { $step.cwd } else { $repoRoot }) `
            -TimeoutMs $TimeoutMs -StdoutFile $logFile
        $res = $stepRes
        if ($res.exit_code -ne 0) { break }
    }
}
Copy-Item -LiteralPath $logFile -Destination $logCanonical -Force -ErrorAction SilentlyContinue

$sw.Stop()
$durationMs = $sw.ElapsedMilliseconds

$allLines = @(($res.stdout -split "`r?`n") + ($res.stderr -split "`r?`n") | Where-Object { $_ })
$diags = Get-FwDiagnostics -Lines $allLines -BaseDir (Resolve-Path $src).Path
$errors = @($diags | Where-Object severity -eq 'error').Count
$warnings = @($diags | Where-Object severity -eq 'warning').Count
$timedOut = $res.timed_out

# ------------------------------------------------------- 4. artifacts
$manifest = Get-FwBackendArtifacts -Backend $backend -ArtifactDir $ArtifactDir -Src $src -BuildDir $BuildDir
$manifest.configuration = $Configuration
if ($projectFile) { $manifest.project_file = $projectFile } else { $manifest.project_file = $null }
$manifestJson = Join-Path $ArtifactDir 'artifacts.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestJson -Encoding utf8

$artifact = if ($manifest.primary) { $manifest.primary.native_path } else { $null }
$artifactHash = $null
if ($artifact) {
    $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
}

$git = Get-FwGitInfo -RepoRoot $repoRoot

# ------------------------------------------------------- 5. result
$base = [ordered]@{
    schema        = 'firmware-build-result/v1'
    configuration = $Configuration
    backend       = $backend
    artifact      = $artifact
    artifact_sha256 = $artifactHash
    warnings      = $warnings
    errors        = $errors
    duration_ms   = $durationMs
    log           = $logCanonical
    artifacts     = $manifest
    git           = $git
    generated_at  = Get-FwTimestamp
}

if ($timedOut) {
    Exit-WithError -Class 'BUILD_ERROR' -Message "Build exceeded timeout (${TimeoutMs} ms) and was killed." -Detail $logFile
}
if ($res.exit_code -ne 0) {
    $base.ok = $false
    $base.artifact = $null
    $base.diagnostics = @($diags | Select-Object file, line, col, severity, message)
    if ($Json) { Write-FwJson ([pscustomobject]$base) -Compact } else { Write-FwJson ([pscustomobject]$base) }
    exit 1
}
if (-not $artifact) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message "Build reported success but no $backend artifact was produced." -Detail $manifestJson
}
$base.ok = $true
if ($Json) { Write-FwJson ([pscustomobject]$base) -Compact } else { Write-FwJson ([pscustomobject]$base) }
exit 0