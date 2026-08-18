# fw.psm1 - FirmwareLoop: shared helpers for PowerShell tools.
# Provides: unified JSON result envelope, Error Class registry (Spec §22),
# python/venv resolution, log saving, compiler diagnostics parsing.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Error Classes (Spec §22 + v0.0.2 §24 additions) --------------------------
$script:FW_ERROR_CLASSES = @(
    'BUILD_ERROR', 'ARTIFACT_NOT_FOUND', 'PROBE_NOT_FOUND', 'TARGET_MISMATCH',
    'FLASH_ERROR', 'FLASH_VERIFY_ERROR', 'RESET_ERROR', 'UART_TIMEOUT',
    'UART_BUSY', 'CAN_ERROR', 'DEBUGGER_ERROR', 'LOGIC_CAPTURE_ERROR',
    'INSTRUMENT_NOT_FOUND', 'INSTRUMENT_TIMEOUT', 'MEASUREMENT_OUT_OF_RANGE',
    'TEST_FAILED', 'PERMISSION_DENIED', 'SAFETY_LIMIT', 'CONFIG_ERROR',
    'UNKNOWN_ERROR',
    # v0.0.2 additions (Gap spec §24)
    'CAPABILITY_NOT_SUPPORTED', 'DEPENDENCY_DISCOVERY_REQUIRED',
    'HARDWARE_GATE_BYPASSED', 'REAL_HARDWARE_REQUIRED', 'HARDWARE_VALIDATION_FAILED'
)

# --- JSON output --------------------------------------------------------------
function Write-FwJson {
    <#
    .SYNOPSIS
        Emit a structured result as JSON. Always UTF-8; deep serialization.
    #>
    param(
        [Parameter(Mandatory = $true)] $Object,
        [switch]$Compact
    )
    $depth = 20
    if ($Compact) {
        $json = $Object | ConvertTo-Json -Depth $depth -Compress
    } else {
        $json = $Object | ConvertTo-Json -Depth $depth
    }
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Write-Output $json
}

function Get-FwErrorClass {
    <#
    .SYNOPSIS
        Validate that a string is a legal Error Class (Spec §22).
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -notin $script:FW_ERROR_CLASSES) {
        throw "Illegal error class '$Name'. Allowed: $($script:FW_ERROR_CLASSES -join ', ')"
    }
    return $Name
}

function New-FwError {
    <#
    .SYNOPSIS
        Deterministic failure envelope. Every external-process failure must
        return one of these (Spec Rule: every operation returns structured errors).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ErrorClass,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Detail = $null,
        [int]$ExitCode = 1
    )
    Get-FwErrorClass $ErrorClass | Out-Null
    $body = [ordered]@{
        ok          = $false
        error_class = $ErrorClass
        error       = $Message
    }
    if ($Detail) { $body.detail = $Detail }
    [pscustomobject]$body
}

# --- Python / venv resolution -------------------------------------------------
function Resolve-FwPython {
    <#
    .SYNOPSIS
        Locate a project Python: prefer .venv\Scripts\python.exe (Windows) or
        .venv/bin/python (Linux/macOS) relative to repo root, then PATH.
        Never hardcoded absolute paths (Spec §25).
    #>
    param([string]$RepoRoot)
    $candidates = @()
    if ($RepoRoot) {
        $candidates += (Join-Path $RepoRoot '.venv\Scripts\python.exe')
        $candidates += (Join-Path $RepoRoot '.venv\bin\python')
        $candidates += (Join-Path $RepoRoot '.venv/bin/python')
        $candidates += (Join-Path $RepoRoot 'venv\Scripts\python.exe')
        $candidates += (Join-Path $RepoRoot 'venv\bin\python')
        $candidates += (Join-Path $RepoRoot 'venv/bin/python')
    }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    $fromPath = Get-Command python3 -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    $fromPath = Get-Command python -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    return $null
}

function Get-FwRepoRoot {
    <#
    .SYNOPSIS
        Root of the firmware project = directory containing tools/ and lab/ (or parent of PSScriptRoot).
    #>
    if ($PSScriptRoot) {
        $candidate = Split-Path -Parent $PSScriptRoot
        if ($candidate -and ((Test-Path (Join-Path $candidate 'tools')) -or (Test-Path (Join-Path $candidate 'pyproject.toml')))) {
            return $candidate
        }
    }
    $cur = (Get-Location).Path
    while ($cur -and (Test-Path -LiteralPath $cur)) {
        if ((Test-Path (Join-Path $cur 'tools')) -and (Test-Path (Join-Path $cur 'lab'))) {
            return $cur
        }
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return (Get-Location).Path
}

function Save-FwLog {
    <#
    .SYNOPSIS
        Append text to a log file under artifacts/logs/ (creates dirs).
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if ($Content -eq '') { $Content = "`n" }
    Add-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function Get-FwTimestamp {
    return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-FwRunId {
    <#
    .SYNOPSIS
        run_id like "20260817-a81f" (Spec §19).
    #>
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $rand = -join ((97..122) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    return "$stamp-$rand"
}

function Get-FwGitInfo {
    <#
    .SYNOPSIS
        {commit, dirty} for audit purposes. Never fails the caller when
        the directory is not a git repo.
    #>
    param([string]$RepoRoot)
    $info = [ordered]@{ commit = $null; dirty = $true }
    if (-not $RepoRoot) { return [pscustomobject]$info }
    $commit = git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $commit) {
        $info.commit = $commit
        $dirtyLines = git -C $RepoRoot status --porcelain 2>$null
        $info.dirty = [bool]($dirtyLines | Where-Object { $_ })
    }
    return [pscustomobject]$info
}

# --- Compiler diagnostics (GCC/Clang "file:line:col: severity: msg") ----------
function Get-FwDiagnostics {
    <#
    .SYNOPSIS
        Parse a compiler log into specified diagnostics entries. Handles both
        "file:line:col: error: message" and bare "error:"/"warning:" lines
        (attributed to the last seen file when possible).
    #>
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [string]$BaseDir = $null
    )
    $diags = [System.Collections.Generic.List[object]]::new()
    $lastFile = $null
    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd()
        if (-not $line) { continue }
        $m = [regex]::Match($line, '^(?<file>.+?):(?<line>\d+):(?<col>\d+):\s*(?<sev>fatal error|error|warning):\s*(?<msg>.*)$')
        if ($m.Success) {
            $file = $m.Groups['file'].Value.Trim('"')
            if ($BaseDir) {
                # Normalize separators so windows/posix mixups don't block the trim.
                $fileNorm = $file.Replace('/', '\')
                $baseNorm = $BaseDir.Replace('/', '\')
                if ($fileNorm.StartsWith($baseNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $file = $fileNorm.Substring($baseNorm.Length).TrimStart('\')
                } else {
                    $file = $fileNorm
                }
            }
            $sev = $m.Groups['sev'].Value
            if ($sev -eq 'fatal error') { $sev = 'error' }
            $diags.Add([pscustomobject]@{
                file     = $file
                line     = [int]$m.Groups['line'].Value
                col      = [int]$m.Groups['col'].Value
                severity = $sev
                message  = $m.Groups['msg'].Value
            })
            $lastFile = $file
            continue
        }
        $m2 = [regex]::Match($line, '^\s*(?<sev>fatal error|error|warning):\s*(?<msg>.*)$')
        if ($m2.Success) {
            $sev = $m2.Groups['sev'].Value
            if ($sev -eq 'fatal error') { $sev = 'error' }
            $diags.Add([pscustomobject]@{
                file     = if ($lastFile) { $lastFile } else { $null }
                line     = $null
                col      = $null
                severity = $sev
                message  = $m2.Groups['msg'].Value
            })
        }
    }
    return ,$diags
}

function Invoke-FwProcess {
    <#
    .SYNOPSIS
        Run an external process with a hard timeout. Every external process
        in this toolchain MUST go through here (Spec Rule 6).
        Returns { exit_code, timed_out, stdout, stderr }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutMs = 300000,
        [string]$StdoutFile = $null,
        [string]$StderrFile = $null
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    try {
        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        if (-not $proc.Start()) {
            return [pscustomobject]@{ exit_code = -1; timed_out = $false; stdout = ''; stderr = 'failed to start' }
        }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $timedOut = -not $proc.WaitForExit($TimeoutMs)
        if ($timedOut) {
            try { $proc.Kill($true) } catch { }
            $proc.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($StdoutFile) {
            Save-FwLog -Path $StdoutFile -Content $stdout
        }
        if ($StderrFile) {
            Save-FwLog -Path $StderrFile -Content $stderr
        }

        return [pscustomobject]@{
            exit_code = $proc.ExitCode
            timed_out = $timedOut
            stdout    = $stdout
            stderr    = $stderr
        }
    }
    catch {
        return [pscustomobject]@{
            exit_code = -1
            timed_out = $false
            stdout    = ''
            stderr    = "failed to launch '$FilePath': $($_.Exception.Message)"
        }
    }
}

function Get-FwLabConfig {
    <#
    .SYNOPSIS
        Parse lab/lab.yaml (or the example fallback) into a PowerShell object.
        YAML is not natively parseable in PowerShell; the project venv python
        + PyYAML does the parsing (release-fix #5: no ConvertFrom-Json on YAML).
    #>
    param([string]$RepoRoot)
    if (-not $RepoRoot) { return $null }
    $python = Resolve-FwPython -RepoRoot $RepoRoot
    if (-not $python) { return $null }
    $candidates = @(
        (Join-Path $RepoRoot 'lab\lab.yaml'),
        (Join-Path $RepoRoot 'lab\lab.example.yaml')
    )
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $script = "import json, sys; sys.stdout.reconfigure(encoding='utf-8', errors='replace');`nimport yaml`nprint(json.dumps(yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}))"
        $res = Invoke-FwProcess -FilePath $python -Arguments @('-c', $script, $path) -TimeoutMs 30000
        if ($res.exit_code -eq 0) {
            try { return ($res.stdout | ConvertFrom-Json) } catch { }
        }
    }
    return $null
}

Export-ModuleMember -Function Write-FwJson, Get-FwErrorClass, New-FwError, `
    Resolve-FwPython, Get-FwRepoRoot, Save-FwLog, Get-FwTimestamp, `
    Get-FwRunId, Get-FwGitInfo, Get-FwDiagnostics, Invoke-FwProcess, Get-FwLabConfig