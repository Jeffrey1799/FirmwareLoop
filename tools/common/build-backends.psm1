# build-backends.psm1 - FirmwareLoop v0.0.2 (GAP-002): build backend registry.
#
# Thin adapter: detection precedence, command construction and artifact
# collection per backend. No build system is reimplemented - each backend
# invokes the official CLI (cmake / make / pio / UV4 / IarBuild / west /
# idf.py). Command construction is testable via -DryRun (tools/build.ps1).

Set-StrictMode -Version Latest

$script:FW_BACKENDS = @('cmake', 'make', 'platformio', 'keil', 'iar', 'zephyr', 'esp-idf')

# ---- strong project markers (checked BEFORE generic CMake) --------------------
$script:FW_MARKERS = @(
    @{ backend = 'zephyr';     marker = 'west.yml' },
    @{ backend = 'esp-idf';    marker = 'sdkconfig' },      # sdkconfig / sdkconfig.defaults
    @{ backend = 'esp-idf';    marker = 'idf.py' },
    @{ backend = 'platformio'; marker = 'platformio.ini' },
    @{ backend = 'keil';       marker = '*.uvproj*' },     # uvproj/uvprojx
    @{ backend = 'iar';        marker = '*.ewp' },
    @{ backend = 'make';       marker = 'Makefile' },
    @{ backend = 'cmake';      marker = 'CMakeLists.txt' }
)

function Find-FwProject {
    <#
    .SYNOPSIS
        Locate the actual project directory for a backend inside a search
        root: root level first, then one directory deep. Returns
        @{ src; project_file } (project_file null when the marker is a dir).
    #>
    param([string]$BackendName, [string]$SearchRoot)
    foreach ($level in @($SearchRoot)) {
        foreach ($m in $script:FW_MARKERS) {
            if ($m.backend -ne $BackendName) { continue }
            $hit = Get-ChildItem -LiteralPath $level -Filter $m.marker -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return [pscustomobject]@{ src = $level; project_file = $hit.FullName } }
        }
    }
    foreach ($sub in (Get-ChildItem -LiteralPath $SearchRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($m in $script:FW_MARKERS) {
            if ($m.backend -ne $BackendName) { continue }
            $hit = Get-ChildItem -LiteralPath $sub.FullName -Filter $m.marker -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return [pscustomobject]@{ src = $sub.FullName; project_file = $hit.FullName } }
        }
    }
    return [pscustomobject]@{ src = $SearchRoot; project_file = $null }
}

function Get-FwBackendDetect {
    <#
    .SYNOPSIS
        Detection precedence (Spec GAP-002): explicit -Backend > project
        config > strong marker > generic detection. Returns
        @{ backend; src; project_file } or $null when nothing found.
    #>
    param(
        [string]$ExplicitBackend,
        [string]$ProjectBackend,
        [string]$SourceDir,
        [string]$RepoRoot
    )
    if ($ExplicitBackend -and $ExplicitBackend -in $script:FW_BACKENDS) {
        $root = if ($SourceDir) { $SourceDir } else { $RepoRoot }
        $found = Find-FwProject -BackendName $ExplicitBackend -SearchRoot $root
        return [pscustomobject]@{ backend = $ExplicitBackend; src = $found.src; project_file = $found.project_file; source = 'explicit' }
    }
    if ($ProjectBackend -and $ProjectBackend -in $script:FW_BACKENDS) {
        $root = if ($SourceDir) { $SourceDir } else { $RepoRoot }
        $found = Find-FwProject -BackendName $ProjectBackend -SearchRoot $root
        return [pscustomobject]@{ backend = $ProjectBackend; src = $found.src; project_file = $found.project_file; source = 'project-config' }
    }

    $candidates = @()
    if ($SourceDir) {
        $candidates += $SourceDir
    } else {
        $candidates += $RepoRoot
        Get-ChildItem -LiteralPath $RepoRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(\.|artifacts|tests|tools|lab|docs|Spec|\.venv|node_modules|demo-make)$' } |
            ForEach-Object { $candidates += $_.FullName }
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        foreach ($m in $script:FW_MARKERS) {
            $hit = Get-ChildItem -LiteralPath $c -Filter $m.marker -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                return [pscustomobject]@{ backend = $m.backend; src = $c; project_file = $hit.FullName; source = 'marker' }
            }
        }
    }
    return $null
}

function Resolve-FwTool {
    <#
    .SYNOPSIS
        Find a tool on PATH or return $null (never throws on missing).
    #>
    param([string]$Name, [string]$Override)
    if ($Override) { return $Override }
    $g = Get-Command $Name -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

function Get-FwBackendCommand {
    <#
    .SYNOPSIS
        Build the official CLI invocation for a backend. Pure construction -
        no execution - so tests can assert command shape (Spec GAP-002
        "Keil command construction" etc). Returns @{ file; args; cwd; label }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$Src,
        [string]$ProjectFile,
        [string]$Configuration = 'Debug',
        [string]$BuildDir,
        [string]$Tool = $null,       # override (fake executable for tests)
        [switch]$AllowMissingTool   # construction tests without installed tools
    )
    $b = $Backend.ToLowerInvariant()
    switch ($b) {
        'cmake' {
            $generator = if (Get-Command ninja -ErrorAction SilentlyContinue) { 'Ninja' } else { 'MinGW Makefiles' }
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'cmake' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:cmake>" } else { return @{ missing = 'cmake' } } }
            return @{
                file = $toolPath
                args = @('-S', $Src, '-B', $BuildDir, '-G', $generator, "-DCMAKE_BUILD_TYPE=$Configuration")
                # follow-up steps executed in order after the configure command
                steps = @(
                    @{ file = $toolPath; args = @('--build', $BuildDir, '--config', $Configuration); cwd = $null }
                )
                cwd  = $null
                label = "cmake -S <src> -B <build> -G $generator -DCMAKE_BUILD_TYPE=$Configuration; cmake --build <build> --config $Configuration"
            }
        }
        'make' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'make' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:make>" } else { return @{ missing = 'make' } } }
            if (-not $toolPath) { return @{ missing = 'make' } }
            return @{
                file = $toolPath
                args = @('-C', $Src, "-CONFIG=$Configuration")
                cwd  = $null
                label = "make -C <src> -CONFIG=$Configuration"
            }
        }
        'platformio' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'pio' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:pio>" } else { return @{ missing = 'pio' } } }
            if (-not $toolPath) { return @{ missing = 'platformio' } }
            return @{
                file = $toolPath
                args = @('run', '-d', $Src, '-e', "$Configuration")
                cwd  = $null
                label = "pio run -d <src> -e <env>"
            }
        }
        'keil' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'UV4' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:UV4>" } else { return @{ missing = 'UV4' } } }
            if (-not $toolPath) { return @{ missing = 'keil' } }
            if (-not $ProjectFile) { return @{ missing = 'keil-project' } }
            return @{
                file = $toolPath
                args = @('-b', $ProjectFile, '-j0')
                cwd  = $null
                label = "UV4 -b <project.uvprojx> -j0"
            }
        }
        'iar' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'IarBuild' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:IarBuild>" } else { return @{ missing = 'IarBuild' } } }
            if (-not $toolPath) { return @{ missing = 'iar' } }
            if (-not $ProjectFile) { return @{ missing = 'iar-project' } }
            return @{
                file = $toolPath
                args = @($ProjectFile, '-build', $Configuration)
                cwd  = $null
                label = "IarBuild <project.ewp> -build <config>"
            }
        }
        'zephyr' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'west' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:west>" } else { return @{ missing = 'west' } } }
            if (-not $toolPath) { return @{ missing = 'zephyr' } }
            $board = $env:ZEPHYR_BOARD
            if (-not $board) { return @{ missing = 'zephyr-board'; detail = 'set ZEPHYR_BOARD (e.g. native_sim) or pass -Configuration' } }
            return @{
                file = $toolPath
                args = @('build', '-d', $BuildDir, '-b', $board, '-p', 'auto')
                cwd  = $Src
                label = "west build -d <build> -b <ZEPHYR_BOARD> -p auto"
            }
        }
        'esp-idf' {
            if ($Tool) { $toolPath = $Tool } else { $toolPath = Resolve-FwTool -Name 'idf.py' }; if (-not $toolPath) { if ($AllowMissingTool) { $toolPath = "<missing:idf.py>" } else { return @{ missing = 'idf.py' } } }
            if (-not $toolPath) { return @{ missing = 'esp-idf' } }
            return @{
                file = $toolPath
                args = @('build')
                cwd  = $Src
                label = "idf.py build (cwd=<src>)"
            }
        }
        default { return @{ missing = $b } }
    }
}

# artifact naming per backend (Spec GAP-002 artifact manifest)
$script:FW_ARTIFACT_PATTERNS = @{
    cmake      = @{ primary = 'firmware.elf'; formats = @('elf'); secondary = @('firmware.hex', 'firmware.bin', 'firmware.map') }
    make       = @{ primary = 'app.elf';      formats = @('elf'); secondary = @('app.hex') }
    keil       = @{ primary = 'app.axf';      formats = @('axf'); secondary = @('app.hex') }
    iar        = @{ primary = 'app.out';      formats = @('out'); secondary = @('app.hex') }
    zephyr     = @{ primary = 'zephyr.elf';   formats = @('elf'); secondary = @('zephyr.hex') }
    'esp-idf'  = @{ primary = 'firmware.elf'; formats = @('elf'); secondary = @('firmware.bin') }
    platformio = @{ primary = 'firmware.elf'; formats = @('elf'); secondary = @('firmware.bin', 'firmware.hex') }
}

# discovery fallback patterns per backend (release-fix #5): when the named
# primary is absent, scan the native output dir for the newest matching image
# (real projects rarely name their binary app.elf/app.axf/app.out).
$script:FW_DISCOVERY_PATTERNS = @{
    make       = @('*.elf', '*.hex')
    keil       = @('*.axf', '*.hex')
    iar        = @('*.out', '*.hex')
    platformio = @('*.elf', '*.bin', '*.hex')
}

function Get-FwBackendArtifacts {
    <#
    .SYNOPSIS
        Collect artifacts per backend into a firmware-artifacts/v1 manifest
        object. Artifacts are located in each backend's NATIVE output
        location (never fabricated, never borrowed from another backend's
        leftovers). Missing files stay absent.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$ArtifactDir,
        [string]$Src,
        [string]$BuildDir
    )
    $pat = $script:FW_ARTIFACT_PATTERNS[$Backend]
    if (-not $pat) { return $null }
    # native output dir per backend
    $outDir = switch ($Backend) {
        'cmake'    { $ArtifactDir }
        'make'     { $Src }
        'keil'     { $Src }
        'iar'      { $Src }
        'zephyr'   { Join-Path $BuildDir 'zephyr' }
        'esp-idf'  { Join-Path $Src 'build' }
        'platformio' { Join-Path $Src '.pio\build' }
        default    { $ArtifactDir }
    }
    $primary = $null
    $secondary = @()
    $pPath = Join-Path $outDir $pat.primary
    if (-not (Test-Path -LiteralPath $pPath)) {
        # artifact discovery (release-fix #5): newest matching image in the
        # native output location, including platformio's per-env subdirs
        $discovery = $script:FW_DISCOVERY_PATTERNS[$Backend]
        if ($discovery) {
            $hits = @()
            foreach ($g in $discovery) {
                $hits += Get-ChildItem -LiteralPath $outDir -Filter $g -File -Recurse -ErrorAction SilentlyContinue
            }
            $newest = $hits | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) { $pPath = $newest.FullName }
        }
    }
    if (Test-Path -LiteralPath $pPath) {
        $primary = [ordered]@{
            path        = $pPath
            format      = ([System.IO.Path]::GetExtension($pPath)).TrimStart('.')
            native_path = (Resolve-Path -LiteralPath $pPath).Path
        }
    }
    foreach ($s in $pat.secondary) {
        $sp = Join-Path $outDir $s
        if (Test-Path -LiteralPath $sp) {
            $secondary += [ordered]@{ path = $sp; format = ([System.IO.Path]::GetExtension($s)).TrimStart('.') }
        }
    }
    return [ordered]@{
        schema        = 'firmware-artifacts/v1'
        backend       = $Backend
        configuration = $null   # filled by caller
        output_dir    = $outDir
        primary       = $primary
        secondary     = $secondary
    }
}

Export-ModuleMember -Function Get-FwBackendDetect, Get-FwBackendCommand, Get-FwBackendArtifacts -Variable FW_BACKENDS