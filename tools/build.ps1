<#
.SYNOPSIS
    Build adapter (Spec §8). Invokes the project's existing build system
    (CMake/Ninja by default; Keil/IAR/ESP-IDF/Zephyr/PlatformIO are detected
    but require their toolchain on PATH) and returns a structured
    firmware-build-result/v1 JSON document.

    Usage:
        .\tools\build.ps1 -Configuration Debug -Json
        .\tools\build.ps1 -SourceDir .\demo-firmware -Json

    Exit codes:
        0  build ok
        1  build failed (compile/link errors)
        2  configuration/toolchain error (CONFIG_ERROR / ARTIFACT_NOT_FOUND)
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Debug',
    [switch]$Json,
    [string]$SourceDir,
    [string]$ArtifactDir,
    [string]$BuildDir,
    [int]$TimeoutMs = 600000,
    [switch]$SkipConfigure,
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$started = Get-Date
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# ---------------------------------------------------------------- backend detection
$candidates = @()
if ($SourceDir) {
    $candidates += $SourceDir
} else {
    $candidates += $repoRoot
    Get-ChildItem -LiteralPath $repoRoot -Directory | Where-Object { $_.Name -notmatch '^(\.|artifacts|tests|tools|lab|docs|\.venv|node_modules)' } | ForEach-Object {
        $candidates += $_.FullName
    }
}

$backend = $null
$src = $null
foreach ($c in $candidates) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    if (Test-Path (Join-Path $c 'CMakeLists.txt')) { $backend = 'cmake'; $src = $c; break }
    if (Test-Path (Join-Path $c 'Makefile')) { $backend = 'make'; $src = $c; break }
    if (Test-Path (Join-Path $c 'platformio.ini')) { $backend = 'platformio'; $src = $c; break }
    if (Get-ChildItem -LiteralPath $c -Filter '*.uvproj*' -ErrorAction SilentlyContinue) { $backend = 'keil'; $src = $c; break }
    if (Get-ChildItem -LiteralPath $c -Filter '*.ewp' -ErrorAction SilentlyContinue) { $backend = 'iar'; $src = $c; break }
}

if (-not $backend) {
    Exit-WithError -Class 'CONFIG_ERROR' -Message 'No build system detected (CMakeLists.txt / Makefile / platformio.ini / *.uvproj* / *.ewp). Pass -SourceDir.' `
        -Detail "Searched: $($candidates -join ', ')"
}

# ---------------------------------------------------------------- toolchain
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
if (-not $cmake) {
    Exit-WithError -Class 'CONFIG_ERROR' -Message "Backend '$backend' requires cmake on PATH." -Detail 'Install CMake (e.g. winget install Kitware.CMake) and retry.'
}
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
$generator = if ($ninja) { 'Ninja' } else { 'MinGW Makefiles' }

if (-not $BuildDir) { $BuildDir = Join-Path $repoRoot "artifacts\build\cmake-$Configuration" }
if (-not $ArtifactDir) { $ArtifactDir = Join-Path $repoRoot 'artifacts\build' }
New-Item -ItemType Directory -Force -Path $BuildDir, $ArtifactDir, (Join-Path $repoRoot 'artifacts\logs') | Out-Null

# Deterministic rebuilds: ninja/cmake on Windows keep coarse mtime granularity,
# so a restored source file can look "unchanged" and be skipped. -Clean wipes
# the binary dir to guarantee every source is recompiled.
if ($Clean) {
    Remove-Item -Recurse -Force -LiteralPath $BuildDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\build-$stamp.log"
$logCanonical = Join-Path $repoRoot 'artifacts\logs\build.log'

# ---------------------------------------------------------------- configure + build
$configureArgs = @('-S', $src, '-B', $BuildDir, '-G', $generator, "-DCMAKE_BUILD_TYPE=$Configuration")
if (-not $SkipConfigure -and -not (Test-Path (Join-Path $BuildDir 'CMakeCache.txt'))) {
    $cfg = Invoke-FwProcess -FilePath $cmake -Arguments $configureArgs -WorkingDirectory $repoRoot -TimeoutMs $TimeoutMs -StdoutFile $logFile
    if ($cfg.exit_code -ne 0) {
        Exit-WithError -Class 'BUILD_ERROR' -Message 'CMake configure failed.' -Detail (($cfg.stdout + $cfg.stderr) | Out-String)
    }
}

$buildArgs = @('--build', $BuildDir, '--config', $Configuration)
$res = Invoke-FwProcess -FilePath $cmake -Arguments $buildArgs -WorkingDirectory $repoRoot -TimeoutMs $TimeoutMs -StdoutFile $logFile

# canonical log: last build always at the documented path
Copy-Item -LiteralPath $logFile -Destination $logCanonical -Force -ErrorAction SilentlyContinue

$sw.Stop()
$durationMs = $sw.ElapsedMilliseconds

$allLines = @(($res.stdout -split "`r?`n") + ($res.stderr -split "`r?`n") | Where-Object { $_ })
$diags = Get-FwDiagnostics -Lines $allLines -BaseDir (Resolve-Path $src).Path
$errors = @($diags | Where-Object severity -eq 'error').Count
$warnings = @($diags | Where-Object severity -eq 'warning').Count
$timedOut = $res.timed_out

# ---------------------------------------------------------------- artifact collection
$artifact = if (Test-Path (Join-Path $ArtifactDir 'firmware.elf')) { Join-Path $ArtifactDir 'firmware.elf' } else { $null }
$secondary = @()
foreach ($ext in @('hex', 'map', 'bin')) {
    $p = Join-Path $ArtifactDir "firmware.$ext"
    if (Test-Path -LiteralPath $p) { $secondary += (Resolve-Path -LiteralPath $p).Path }
}
$artifactHash = $null
if ($artifact) {
    $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
}

$git = Get-FwGitInfo -RepoRoot $repoRoot

# ---------------------------------------------------------------- result
if ($res.exit_code -eq 0 -and -not $timedOut -and $artifact) {
    $result = [ordered]@{
        schema             = 'firmware-build-result/v1'
        ok                 = $true
        configuration      = $Configuration
        backend            = $backend
        artifact           = (Resolve-Path -LiteralPath $artifact).Path
        artifact_sha256    = $artifactHash
        secondary_artifacts = @($secondary | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
        warnings           = $warnings
        errors             = $errors
        duration_ms        = $durationMs
        log                = (Resolve-Path -LiteralPath $logCanonical).Path
        git                = $git
        generated_at       = Get-FwTimestamp
    }
    if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
    exit 0
}

if ($timedOut) {
    Exit-WithError -Class 'BUILD_ERROR' -Message "Build exceeded timeout (${TimeoutMs} ms) and was killed." -Detail $logFile
}

if ($res.exit_code -ne 0) {
    $result = [ordered]@{
        schema        = 'firmware-build-result/v1'
        ok            = $false
        configuration = $Configuration
        backend       = $backend
        artifact      = $null
        warnings      = $warnings
        errors        = $errors
        duration_ms   = $durationMs
        log           = $logCanonical
        diagnostics   = @($diags | Select-Object file, line, col, severity, message)
        git           = $git
        generated_at  = Get-FwTimestamp
    }
    if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
    exit 1
}

# exit 0 but artifact missing
Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message 'Build reported success but artifacts/build/firmware.elf was not produced.' `
    -Detail "Searched: $ArtifactDir (log: $logCanonical)"