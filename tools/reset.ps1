<#
.SYNOPSIS
    DUT reset (Spec §26 M2). Preferred backend is Agentic HIL; the
    simulator backend is a no-op acknowledgement (the HIL harness owns the
    simulated DUT process and resets it in-test).

    Usage:
        .\tools\reset.ps1 -Backend simulator -Json
        .\tools\reset.ps1 -Backend agentic-hil -Json

    Exit codes: 0 ok, 1 backend failure, 2 config/identity error.
#>
[CmdletBinding()]
param(
    [ValidateSet('simulator', 'agentic-hil', 'openocd', 'vendor')]
    [string]$Backend = 'simulator',
    [string]$ExpectedTarget,          # verify probe identity before reset (Spec §9)
    [switch]$Json
)

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

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $repoRoot "artifacts\logs\reset-$stamp.log"
New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null

switch ($Backend) {
    'simulator' {
        Save-FwLog -Path $logFile -Content "simulator backend: reset is managed by the HIL harness (pytest conftest SimulatedDut.reset)."
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'simulator'
            target      = 'simulated-dut'
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
            Exit-WithError -Class 'TOOLCHAIN_NOT_FOUND' -Message 'pyocd 未找到。请在 Python 环境中安装 pyocd (`uv pip install pyocd`)。' -Detail 'pyOCD 用于通过 ST-LINK / CMSIS-DAP 复位芯片。'
        }
        $targetChip = if ($ExpectedTarget) { $ExpectedTarget } else { 'stm32f103rc' }
        $res = Invoke-FwProcess -FilePath $pyocdExe -Arguments @('reset', '-t', $targetChip.ToLowerInvariant()) -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'TIMEOUT' -Message 'pyocd 芯片复位超时。' -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'RESET_ERROR' -Message "pyocd 硬件复位失败：探针未连接或目标 MCU 无响应。" -Detail ($res.stdout + "`n" + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'pyocd'
            target      = $targetChip
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
            Exit-WithError -Class 'TOOLCHAIN_NOT_FOUND' -Message '未找到 SEGGER JLink.exe。' -Detail '请安装官方 SEGGER J-Link 驱动。'
        }
        $cmdScript = Join-Path $repoRoot "artifacts\logs\jlink_reset_$stamp.jlink"
        Set-Content -LiteralPath $cmdScript -Value "r`ng`nq`n" -Encoding ASCII
        $targetChip = if ($ExpectedTarget) { $ExpectedTarget } else { 'STM32F103C8' }
        $res = Invoke-FwProcess -FilePath $jlinkExe -Arguments @('-device', $targetChip, '-if', 'SWD', '-speed', '4000', '-autoconnect', '1', '-CommanderScript', $cmdScript) -WorkingDirectory $repoRoot -TimeoutMs 30000 -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'TIMEOUT' -Message 'J-Link 芯片复位超时。' -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'RESET_ERROR' -Message "J-Link 硬件复位失败：探针未连接或板卡未供电。" -Detail ($res.stdout + "`n" + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'jlink'
            target      = $targetChip
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    'agentic-hil' {
        $cmd = Get-Command agentic-hil -ErrorAction SilentlyContinue
        if (-not $cmd) {
            Exit-WithError -Class 'PROBE_NOT_FOUND' -Message "'agentic-hil' 未安装；请安装 Agentic HIL。" -Detail 'See README.md -> M2'
        }
        $res = Invoke-FwProcess -FilePath $cmd.Source -Arguments @('reset', '--target', $ExpectedTarget, '--json') -WorkingDirectory $repoRoot -TimeoutMs 120000 -StdoutFile $logFile
        if ($res.timed_out) {
            Exit-WithError -Class 'RESET_ERROR' -Message 'reset backend timed out and was killed.' -Detail $logFile
        }
        if ($res.exit_code -ne 0) {
            Exit-WithError -Class 'RESET_ERROR' -Message 'reset backend reported failure.' -Detail ($res.stdout + $res.stderr)
        }
        $result = [ordered]@{
            schema      = 'firmware-reset-result/v1'
            ok          = $true
            backend     = 'agentic-hil'
            target      = $ExpectedTarget
            log         = (Resolve-Path -LiteralPath $logFile).Path
            generated_at = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
        exit 0
    }
    default {
        Exit-WithError -Class 'CONFIG_ERROR' -Message "复位后端 '$Backend' 尚未在本机配置。" -Detail '请在 lab/lab.yaml 中配置有效的复位后端。'
    }
}