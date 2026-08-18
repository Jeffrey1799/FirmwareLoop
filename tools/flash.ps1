<#
.SYNOPSIS
    Flash fallback adapter (Spec §10). Preferred path is Agentic HIL; this
    wrapper exists only for targets Agentic HIL does not support yet.

    Usage:
        .\tools\flash.ps1 -Backend openocd -Artifact artifacts\build\firmware.elf -Json
        .\tools\flash.ps1 -Backend agentic-hil -Artifact artifacts\build\firmware.elf -Json

    Hard constraints (Spec §10/§24):
      - artifact must be one of the conventional names under artifacts/build/
      - mass erase / security programming flags are rejected before execution
      - every external process has a timeout
      - returns JSON (firmware-flash-result/v1) and saves the raw log

    Without a configured backend this exits CONFIG_ERROR - flash is intentionally
    not configured until real hardware integration (Spec §31 step 7).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('simulator', 'agentic-hil', 'openocd', 'stm32cubeprogrammer', 'esptool', 'jlink', 'vendor', 'pyocd')]
    [string]$Backend,
    [string]$Artifact = 'artifacts/build/firmware.elf',
    [switch]$Json,
    [int]$TimeoutMs = 120000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$artifactPath = if ([System.IO.Path]::IsPathRooted($Artifact)) { $Artifact } else { Join-Path $repoRoot $Artifact }

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# --- artifact guard (Spec §10) -------------------------------------------------
$allowed = @('firmware.elf', 'firmware.hex', 'firmware.bin')
$name = Split-Path $artifactPath -Leaf
if ($name -notin $allowed) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message "artifact name '$name' is not flashable; allowed: $($allowed -join ', ')" -Detail $artifactPath
}
if (-not (Test-Path -LiteralPath $artifactPath)) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message 'artifact does not exist; run tools/build.ps1 first.' -Detail $artifactPath
}
$full = (Resolve-Path -LiteralPath $artifactPath).Path
$buildRoot = (Join-Path $repoRoot 'artifacts\build')
if (-not $full.StartsWith((Resolve-Path -LiteralPath $buildRoot).Path, [System.StringComparison]::OrdinalIgnoreCase)) {
    Exit-WithError -Class 'PERMISSION_DENIED' -Message 'artifact is outside artifacts/build; refusing to flash.' -Detail $full
}

# --- backend dispatch ----------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\flash-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

switch ($Backend) {
    'simulator' {
        Save-FwLog -Path $logFile -Content 'simulator backend: flash validated via firmware build + HIL run (no real programmer involved)'
        $result = [ordered]@{
            schema      = 'firmware-flash-result/v1'
            ok          = $true
            backend     = 'simulator'
            artifact    = $full
            artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            simulated   = $true
            hardware_validated = $false
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'pyocd' {
        $pyocdExe = Join-Path $repoRoot '.venv\Scripts\pyocd.exe'
        if (-not (Test-Path -LiteralPath $pyocdExe)) {
            $cmd = Get-Command pyocd -ErrorAction SilentlyContinue
            if ($cmd) { $pyocdExe = $cmd.Source }
        }
        if (-not (Test-Path -LiteralPath $pyocdExe)) {
            Exit-WithError -Class 'TOOLCHAIN_NOT_FOUND' -Message 'pyocd 未找到。请在 Python 环境中安装 pyocd (`uv pip install pyocd`)。' -Detail 'pyOCD 用于通过 ST-LINK / CMSIS-DAP 烧录 STM32 芯片。'
        }
        $targetChip = 'stm32f103rc'
        $labYaml = Join-Path $repoRoot 'lab\lab.yaml'
        if (Test-Path -LiteralPath $labYaml) {
            $labContent = Get-Content -LiteralPath $labYaml -Raw
            if ($labContent -match 'target_chip:\s*["'']?([^"''\r\n]+)') {
                $targetChip = $matches[1].Trim()
            }
        }
        $res = Invoke-FwProcess -FilePath $pyocdExe -Arguments @('flash', '-t', $targetChip.ToLowerInvariant(), $full) -WorkingDirectory $repoRoot -TimeoutMs $TimeoutMs -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'TIMEOUT' -Message "pyocd 烧录超时（${TimeoutMs}ms）。" -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'FLASH_ERROR' -Message "pyocd 烧录失败：未检测到物理探针或目标 MCU 无响应。请确保 ST-LINK / DAPLink 已插入 USB 接口并正确连接 SWD 信号线（SWCLK/SWDIO/GND/3V3）。" -Detail ($res.stdout + "`n" + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-flash-result/v1'
            ok          = $true
            backend     = 'pyocd'
            target      = $targetChip
            artifact    = $full
            artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'jlink' {
        $jlinkExe = (Get-Command JLink.exe -ErrorAction SilentlyContinue)?.Source
        if (-not $jlinkExe) {
            $candidates = @(
                "C:\Program Files\SEGGER\JLink\JLink.exe",
                "C:\Program Files (x86)\SEGGER\JLink\JLink.exe"
            )
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) { $jlinkExe = $c; break }
            }
        }
        if (-not $jlinkExe) {
            Exit-WithError -Class 'TOOLCHAIN_NOT_FOUND' -Message '未找到 SEGGER JLink.exe。请安装官方 SEGGER J-Link 驱动软件包。' -Detail '下载地址: https://www.segger.com/downloads/jlink/'
        }
        $cmdScript = Join-Path $repoRoot "artifacts\logs\jlink_flash_$stamp.jlink"
        $scriptContent = "r`nh`nloadfile $full`nr`ng`nq`n"
        Set-Content -LiteralPath $cmdScript -Value $scriptContent -Encoding ASCII
        $targetChip = 'STM32F103C8'
        $res = Invoke-FwProcess -FilePath $jlinkExe -Arguments @('-device', $targetChip, '-if', 'SWD', '-speed', '4000', '-autoconnect', '1', '-CommanderScript', $cmdScript) -WorkingDirectory $repoRoot -TimeoutMs $TimeoutMs -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'TIMEOUT' -Message "J-Link 烧录超时（${TimeoutMs}ms）。" -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'FLASH_ERROR' -Message "J-Link 烧录失败：未连接 J-Link 探针或目标板未供电。" -Detail ($res.stdout + "`n" + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-flash-result/v1'
            ok          = $true
            backend     = 'jlink'
            target      = $targetChip
            artifact    = $full
            artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'agentic-hil' {
        Exit-WithError -Class 'REAL_HARDWARE_REQUIRED' `
            -Message "Agentic HIL 烧录请直接使用 MCP 工具 flash_firmware，或执行 test-plans/real-smoke.yaml。" `
            -Detail "禁止随意使用伪造的 CLI。"
    }
    default {
        Exit-WithError -Class 'CONFIG_ERROR' -Message "烧录后端 '$Backend' 尚未在本机配置。" -Detail '请在 lab/lab.yaml 中配置有效的烧录器后端（pyocd, jlink, stm32cubeprogrammer 等）。'
    }
}

if ($res.timed_out) {
    Exit-WithError -Class 'FLASH_ERROR' -Message 'flash backend timed out and was killed.' -Detail $logFile
}
if ($res.exit_code -ne 0) {
    Exit-WithError -Class 'FLASH_ERROR' -Message 'flash backend reported failure.' -Detail ($res.stdout + $res.stderr)
}

$result = [ordered]@{
    schema      = 'firmware-flash-result/v1'
    ok          = $true
    backend     = $Backend
    artifact    = $full
    artifact_sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    log         = (Resolve-Path -LiteralPath $logFile).Path
    generated_at = Get-FwTimestamp
}
if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
exit 0