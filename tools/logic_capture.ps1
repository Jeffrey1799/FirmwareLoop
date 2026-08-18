<#
.SYNOPSIS
    Logic analyzer capture (Spec §13). Saleae is the primary path (Logic 2 MCP
    in Qoder); this wrapper covers the sigrok fallback for non-Saleae hardware
    and provides a deterministic SIMULATOR backend so the capture->decode->
    assert pipeline can be exercised without any LA hardware.

    Every capture saves (Spec §13): raw capture file, decoder config snapshot,
    and a metadata JSON with the timestamp - under artifacts/captures/.

    Usage:
        .\tools\logic_capture.ps1 -Protocol spi -Json            # simulator (default)
        .\tools\logic_capture.ps1 -Protocol uart -Backend sigrok -Json
#>
[CmdletBinding()]
param(
    [ValidateSet('spi', 'uart', 'i2c')]
    [string]$Protocol = 'spi',
    [ValidateSet('auto', 'simulator', 'sigrok')]
    [string]$Backend = 'auto',
    [double]$DurationSec = 0.002,
    [int]$SampleRateHz = 1000000,
    [string]$OutDir,                          # default: artifacts/captures/<stamp>
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

# ---- decide backend -----------------------------------------------------------
if ($Backend -eq 'auto') {
    $g = Get-Command sigrok-cli -ErrorAction SilentlyContinue
    $sigrok = if ($g) { $g.Source } else { $null }
    $Backend = if ($sigrok) { 'sigrok' } else { 'simulator' }
}
if ($Backend -eq 'sigrok') {
    $g = Get-Command sigrok-cli -ErrorAction SilentlyContinue
    $sigrok = if ($g) { $g.Source } else { $null }
    if (-not $sigrok) {
        Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'sigrok-cli not found; install sigrok or use -Backend simulator' -Detail 'https://sigrok.org/wiki/Downloads'
    }
}

# ---- output layout ------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runId = Get-FwRunId
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "artifacts\captures\$runId" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# decoder config snapshot (read from lab/protocol-decode.yaml if present)
$decodeCfg = Join-Path $repoRoot 'lab\protocol-decode.yaml'
$configOut = Join-Path $OutDir 'decoder-config.yaml'
if (Test-Path -LiteralPath $decodeCfg) {
    Copy-Item -LiteralPath $decodeCfg -Destination $configOut -Force
} else {
    Set-Content -LiteralPath $configOut -Value "# decoder config snapshot (protocol-decode.yaml not found at capture time)" -Encoding utf8
}

$meta = [ordered]@{
    schema       = 'lab-logic-capture/v1'
    ok           = $true
    run_id       = $runId
    protocol     = $Protocol
    backend      = $Backend
    duration_sec = $DurationSec
    sample_rate_hz = $SampleRateHz
    timestamp    = Get-FwTimestamp
    files        = @()
}

# ---- simulator waveform generation --------------------------------------------
if ($Backend -eq 'simulator') {
    $rawFile = Join-Path $OutDir 'capture.csv'
    $meta.protocol = $Protocol
    switch ($Protocol) {
        'spi' { $generator = 'SPI transaction: 0x9F read + 24-bit response 0xEF4018' }
        'uart' { $generator = 'UART frame: "HIL" at 115200 8N1' }
        'i2c' { $generator = 'I2C write to 0x50 then read 3 bytes' }
        default { $generator = 'unknown' }
    }
    $rows = New-Object System.Collections.Generic.List[string]
    $rows.Add('time_s,D0,D1,D2,D3')

    function Add-Sample {
        param([double]$T, [int[]]$Levels)
        $rows.Add(('{0:F8},{1},{2},{3},{4}' -f $T, $Levels[0], $Levels[1], $Levels[2], $Levels[3]))
    }

    $dt = 1.0 / $SampleRateHz
    $t = 0.0

    if ($Protocol -eq 'spi') {
        # Channels: D0=SCLK, D1=MOSI, D2=MISO, D3=CS (low active)
        # One bit = 1us at 1 MHz SCLK === 1 sample per half-bit at 1MHz? Use
        # 2 samples per bit: low phase then high (rising edge sampled).
        $bitUs = 2e-6   # 2us per bit -> 500 kHz SCLK
        $bits = @()    # command bits MSB first
        foreach ($b in (0x9F)) { for ($i = 7; $i -ge 0; $i--) { $bits += ($b -shr $i) -band 1 } }
        $resp = @(0xEF, 0x40, 0x18)
        $respBits = @()
        foreach ($bb in $resp) { for ($i = 7; $i -ge 0; $i--) { $respBits += ($bb -shr $i) -band 1 } }

        # idle (CS high)
        $idleSamples = [math]::Max(2, [int](0.00005 / $dt))
        for ($i = 0; $i -lt $idleSamples; $i++) {
            Add-Sample $t @(0, 0, 0, 1)
            $t += $dt
        }
        # CS assert
        $csLevels = @(0, 0, 0, 0)
        for ($i = 0; $i -lt 2; $i++) { Add-Sample $t $csLevels; $t += $dt }
        # command + response bits: first 8 bits drive MOSI, next 24 drive MISO
        $allBits = $bits + $respBits
        for ($idx = 0; $idx -lt $allBits.Count; $idx++) {
            $bit = $allBits[$idx]
            $isCmd = $idx -lt 8
            $mosi = if ($isCmd) { $bit } else { 0 }
            $miso = if ($isCmd) { 0 } else { $bit }
            # low phase
            for ($i = 0; $i -lt [int]($bitUs / 2 / $dt); $i++) {
                if ($mosi -eq 1) { Add-Sample $t @(0, 1, $miso, 0) } else { Add-Sample $t @(0, 0, $miso, 0) }
                $t += $dt
            }
            # high phase (rising edge; MISO valid here)
            for ($i = 0; $i -lt [int]($bitUs / 2 / $dt); $i++) {
                if ($mosi -eq 1) { Add-Sample $t @(1, 1, $miso, 0) } else { Add-Sample $t @(1, 0, $miso, 0) }
                $t += $dt
            }
        }
        # CS deassert
        for ($i = 0; $i -lt 2; $i++) { Add-Sample $t @(0, 0, 0, 1); $t += $dt }
    } elseif ($Protocol -eq 'uart') {
        # Channels: D0=TX, D1=RX, D2=unused, D3=unused
        $bitTime = 1.0 / 115200.0
        function Add-Bit {
            param([double]$TT, [int]$Level, [double]$BitLen)
            $n = [math]::Max(1, [int]($BitLen / $dt))
            for ($i = 0; $i -lt $n; $i++) {
                Add-Sample $TT @($Level, 1, 0, 0)
                $TT += $dt
            }
            return $TT
        }
        $payloadBytes = [System.Text.Encoding]::ASCII.GetBytes('HIL')
        $idleN = [math]::Max(2, [int]((10 * $bitTime) / $dt))
        for ($i = 0; $i -lt $idleN; $i++) { Add-Sample $t @(1, 1, 0, 0); $t += $dt }
        foreach ($byte in $payloadBytes) {
            $t = Add-Bit $t 0 $bitTime           # start bit
            for ($i = 0; $i -lt 8; $i++) {        # LSB first
                $t = Add-Bit $t (($byte -shr $i) -band 1) $bitTime
            }
            $t = Add-Bit $t 1 $bitTime            # stop bit
            # inter-frame gap (like software-driven UART transmit)
            $gapN = [math]::Max(2, [int]((10 * $bitTime) / $dt))
            for ($i = 0; $i -lt $gapN; $i++) { Add-Sample $t @(1, 1, 0, 0); $t += $dt }
        }
    } else {  # i2c
        # Channels: D0=SCL, D1=SDA; write transaction: START, addr 0xA0,
        # reg 0x00 with ACKs, STOP.
        $bitTime = 1.0 / 100000.0
        function Add-I2CBit {
            param([double]$TT, [int]$SdaLevel, [double]$BitLen)
            $n = [math]::Max(1, [int]($BitLen / $dt))
            for ($i = 0; $i -lt $n; $i++) {
                Add-Sample $TT @(0, $SdaLevel, 0, 0)
                $TT += $dt
            }
            # clock high
            $nh = [math]::Max(1, [int]($BitLen / $dt))
            for ($i = 0; $i -lt $nh; $i++) {
                Add-Sample $TT @(1, $SdaLevel, 0, 0)
                $TT += $dt
            }
            return $TT
        }
        function Add-I2CHold {
            param([double]$TT, [int]$SdaLevel, [double]$Secs)
            $n = [math]::Max(1, [int]($Secs / $dt))
            for ($i = 0; $i -lt $n; $i++) {
                Add-Sample $TT @(1, $SdaLevel, 0, 0)   # SCL stays high
                $TT += $dt
            }
            return $TT
        }
        $hold = $bitTime / 2

        # idle (bus free: SCL high, SDA high)
        $idleN = [math]::Max(2, [int]((4 * $bitTime) / $dt))
        for ($i = 0; $i -lt $idleN; $i++) { Add-Sample $t @(1, 1, 0, 0); $t += $dt }
        # START: SDA falls while SCL is high
        $t = Add-I2CHold $t 0 $hold
        Add-Sample $t @(1, 0, 0, 0); $t += $dt
        $t = Add-I2CHold $t 0 $hold
        # address + data bytes with ACK after each
        foreach ($byte in @(0xA0, 0x00)) {
            foreach ($i in 7..0) {
                $t = Add-I2CBit $t (($byte -shr $i) -band 1) $bitTime
            }
            $t = Add-I2CBit $t 0 $bitTime  # ACK
        }
        # STOP: SDA rises while SCL is high
        $t = Add-I2CHold $t 0 $hold
        Add-Sample $t @(1, 1, 0, 0); $t += $dt
        $t = Add-I2CHold $t 1 $hold
    }

    Set-Content -LiteralPath $rawFile -Value $rows -Encoding utf8
    $meta.files += (Resolve-Path -LiteralPath $rawFile).Path
    $meta.generator = $generator
}

# ---- sigrok backend ------------------------------------------------------------
else {
    $rawFile = Join-Path $OutDir 'capture.sr'
    $probeArgs = @(
        "--driver=auto",
        "--config", "samplerate=$SampleRateHz",
        "--channels", "0-7",
        "--output-format", "binary",
        "--output-file", $rawFile,
        "--time", "$([int]([math]::Ceiling($DurationSec * 1000)))ms",
        "$Protocol"
    )
    $res = Invoke-FwProcess -FilePath $sigrok -Arguments $probeArgs -WorkingDirectory $repoRoot -TimeoutMs 120000
    if ($res.timed_out) {
        Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'sigrok-cli capture timed out.' -Detail $rawFile
    }
    if ($res.exit_code -ne 0 -or -not (Test-Path -LiteralPath $rawFile)) {
        Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'sigrok-cli capture failed.' -Detail ($res.stdout + $res.stderr)
    }
    $meta.files += (Resolve-Path -LiteralPath $rawFile).Path
}

$metaFile = Join-Path $OutDir 'capture.json'
$meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metaFile -Encoding utf8
$meta.files += (Resolve-Path -LiteralPath $metaFile).Path

$result = [ordered]@{
    schema         = 'lab-logic-capture/v1'
    ok             = $true
    protocol       = $Protocol
    backend        = $Backend
    capture        = (Resolve-Path -LiteralPath $rawFile).Path
    metadata       = (Resolve-Path -LiteralPath $metaFile).Path
    decoder_config = (Resolve-Path -LiteralPath $configOut).Path
    files          = @($meta.files)
    run_id         = $runId
    timestamp      = Get-FwTimestamp
}
if ($Json) { Write-FwJson ([pscustomobject]$result) -Compact } else { Write-FwJson ([pscustomobject]$result) }
exit 0